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
    @State private var presetName = ""

    enum Tab: String, CaseIterable, Identifiable {
        case info, adjust, film, export
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .info: "info.circle"
            case .adjust: "slider.horizontal.3"
            case .film: "film"
            case .export: "square.and.arrow.up"
            }
        }
        var title: LocalizedStringKey {
            switch self {
            case .info: "Info"
            case .adjust: "Adjust"
            case .film: "Film"
            case .export: "Export"
            }
        }
    }

    static let labels = ["red", "orange", "yellow", "green", "blue", "purple"]

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
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                ForEach(Tab.allCases) { item in
                    Button { tab = item } label: {
                        Image(systemName: item.symbol)
                            .font(.system(size: 14, weight: .medium))
                            .frame(maxWidth: .infinity, minHeight: 28)
                            .foregroundStyle(tab == item ? Color.accentColor : .secondary)
                            .background(RoundedRectangle(cornerRadius: Design.Radius.small).fill(tab == item ? Color.accentColor.opacity(0.14) : .clear))
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .help(Text(item.title))
                }
            }
            .padding(6)
            Divider()
            HStack {
                Text(tab.title).font(.headline)
                Spacer()
                if paths.count > 1 {
                    Text("^[\(paths.count) photo](inflect: true)").font(.caption.weight(.semibold))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(Design.Brand.gradient)).foregroundStyle(.white)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 6)
            if paths.isEmpty {
                Text("Select a photo.").font(.callout).foregroundStyle(.secondary).padding(14)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        switch tab {
                        case .info: info
                        case .adjust: adjust
                        case .film: PhotoFilmPanel(paths: paths, record: record)
                        case .export: PhotoExportPanel(paths: paths)
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.bottom, 14)
                }
            }
        }
        .background(.background.secondary)
    }

    private func change(_ body: @escaping (inout PhotoRecord) -> Void) {
        catalog.update(paths) { record in
            body(&record)
            record.edited = .now
        }
    }

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
            SidebarSection(title: Text("Settings")) {
                HStack(spacing: 8) {
                    Button("Copy") { PhotoInspector.clipboard = record }
                        .help("Copy this photo’s adjustments and film")
                    Button("Paste") {
                        guard let copied = PhotoInspector.clipboard else { return }
                        change { $0.adjust = copied.adjust.keepingDecoder(of: $0.adjust); $0.film = copied.film; $0.filmOn = copied.filmOn }
                    }
                    .disabled(PhotoInspector.clipboard == nil)
                    .help("Give the selected photos the copied adjustments and film")
                    Spacer()
                    Button("Reset", role: .destructive) { change { $0.adjust = PhotoAdjustments(); $0.filmOn = false; $0.film = FilmSettings() } }
                }
                .controlSize(.small)
                .padding(.horizontal, 8)
            }
        }
    }

    @MainActor static var clipboard: PhotoRecord?

    // MARK: - Adjust

    private var adjust: some View {
        let raw = shown.map(PhotoRender.isRaw) ?? false
        return VStack(alignment: .leading, spacing: 10) {
            if !editing.histogram.isEmpty { HistogramView(bins: editing.histogram) }
            HStack(spacing: 8) {
                Picker("Profile", selection: Binding(get: { record.adjust.profile ?? (raw ? .neutral : .asShot) },
                                                     set: { value in change { $0.adjust.profile = value } })) {
                    ForEach(PhotoEngine.Profile.allCases.filter { raw ? $0 != .asShot : true }) { Text($0.title).tag($0) }
                }
                .fixedSize()
                .help("The starting point: how the light becomes a picture, the same for every camera")
                Spacer(minLength: 0)
                Button("Auto") { autoTone() }
                    .help("Exposure, highlights, shadows, whites and blacks for this photo")
                presetsMenu
            }
            .controlSize(.small)
            .padding(.horizontal, 8)
            if record.adjust.process < PhotoAdjustments.currentProcess {
                // Edited with the first engine: kept as it was until asked.
                HStack(spacing: 8) {
                    Label("Earlier engine", systemImage: "clock.arrow.circlepath").font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button("Update") { change { $0.adjust.process = PhotoAdjustments.currentProcess } }
                        .help("Develop with the current engine: wider colour, white balance, tone curve and dehaze. The look changes a little.")
                }
                .controlSize(.small)
                .padding(.horizontal, 8)
            }
            FoldSection(title: "Light", key: "light") {
                slider("Exposure", \.exposure, -5...5, format: "%+.2f")
                slider("Contrast", \.contrast, -100...100)
                slider("Highlights", \.highlights, -100...100)
                slider("Shadows", \.shadows, -100...100)
                slider("Whites", \.whites, -100...100)
                slider("Blacks", \.blacks, -100...100)
            }
            FoldSection(title: "Colour", key: "colour") {
                if raw, let path = shown {
                    let kelvin = PhotoEngine.kelvin(record.adjust, asShot: PhotoRender.asShotKelvin(path))
                    slider("Temperature", \.temperature, -100...100, label: "\(Int((kelvin / 50).rounded() * 50)) K")
                } else {
                    slider("Temperature", \.temperature, -100...100)
                }
                slider("Tint", \.tint, -100...100)
                slider("Vibrance", \.vibrance, -100...100)
                slider("Saturation", \.saturation, -100...100)
            }
            FoldSection(title: "Presence", key: "presence") {
                slider("Texture", \.texture, -100...100)
                slider("Clarity", \.clarity, -100...100)
                slider("Dehaze", \.dehaze, -100...100)
                slider("Vignette", \.vignette, -100...100)
            }
            FoldSection(title: "Masks", key: "masks", open: false) {
                masksSection
            }
            FoldSection(title: "Colour Mixer", key: "mixer", open: false) {
                ColorMixerEditor(mixer: record.adjust.mixer) { mixer in change { $0.adjust.mixer = mixer } }
            }
            FoldSection(title: "Curves", key: "curves", open: false) {
                CurvesEditor(curves: record.adjust.curves) { curves in change { $0.adjust.curves = curves } }
            }
            FoldSection(title: "Colour Wheels", key: "wheels", open: false) {
                ColorWheelsEditor(wheels: record.adjust.wheels) { wheels in change { $0.adjust.wheels = wheels } }
            }
            FoldSection(title: "Detail", key: "detail", open: false) {
                slider("Sharpen", \.sharpen, 0...100)
                slider("Noise", \.noise, 0...100)
                if raw { slider("Moiré", \.moire, 0...100) }
                denoise
            }
            FoldSection(title: "Crop", key: "crop") {
                HStack(spacing: 6) {
                    Picker("Aspect", selection: Binding(get: { record.adjust.crop }, set: { value in
                        change { $0.adjust.crop = value; $0.adjust.cropRect = nil }
                        if value != .original { editing.cropping = true }
                    })) {
                        ForEach(PhotoAdjustments.Crop.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    Button {
                        change { $0.adjust.cropPortrait = !($0.adjust.cropPortrait ?? portraitPhoto); $0.adjust.cropRect = nil }
                    } label: {
                        Image(systemName: (record.adjust.cropPortrait ?? portraitPhoto) ? "rectangle.portrait" : "rectangle")
                    }
                    .disabled(record.adjust.crop.shortOverLong == nil || record.adjust.crop == .square)
                    .help("Turn the crop upright or on its side (X)")
                    Spacer()
                    Button(editing.cropping ? "Done" : "Crop") { editing.cropping.toggle() }
                        .help("Show the crop frame on the photo (C)")
                }
                .font(.callout)
                .controlSize(.small)
                .padding(.horizontal, 8)
                slider("Straighten", \.straighten, -45...45, format: "%+.1f°")
            }
            Button("Reset Adjustments") { change { $0.adjust = PhotoAdjustments() } }
                .buttonStyle(.link)
                .padding(.horizontal, 8)
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
                        Label(mask.kind.title, systemImage: mask.kind.symbol).font(.callout.weight(.medium))
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
            Text(title).foregroundStyle(.secondary).lineLimit(1).frame(width: 84, alignment: .leading)
            Slider(value: Binding(get: { value }, set: { new in
                change { record in if let i = record.adjust.masks.firstIndex(where: { $0.id == mask.id }) { record.adjust.masks[i][keyPath: path] = new } }
            }), in: range)
            Text(String(format: format, value)).font(.caption.monospacedDigit()).foregroundStyle(value == 0 ? .tertiary : .primary)
                .frame(width: 44, alignment: .trailing)
        }
        .font(.callout)
        .controlSize(.small)
        .padding(.horizontal, 8)
        .frame(minHeight: 24)
    }

    /// Lightroom's Auto, from the photo developed plain, for each photo being edited.
    private func autoTone() {
        let targets = paths
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

    @State private var denoiseStrength = 50.0
    @State private var film = FilmEngine.shared

    @AppStorage("photoDenoiseAI") private var denoiseAI = false

    /// Denoise: a slower, better noise reduction at full size, done once and kept. Standard
    /// (non-local means) or AI (a network trained on real camera noise, an optional download).
    private var denoise: some View {
        let busy = paths.filter(editing.denoising.contains).count
        return VStack(alignment: .leading, spacing: 6) {
            if film.denoiseEngine != .ready {
                switch film.denoiseEngine {
                case .installing:
                    ProgressView(value: film.denoiseProgress)
                    Text("Getting the denoise engine…").font(.caption).foregroundStyle(.secondary)
                case .failed(let message):
                    ProblemLabel(text: message)
                    Button("Try Again") { film.installDenoiseEngine() }
                default:
                    Text("Removes noise at full size, done once per photo. Runs on this Mac.").font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Get Denoise (\(FilmEngine.denoiseEngineDownloadMB) MB)", systemImage: "arrow.down") { film.installDenoiseEngine() }
                }
            } else if busy > 0 {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Removing noise from ^[\(busy) photo](inflect: true)…").font(.callout).foregroundStyle(.secondary)
                }
            } else {
                Picker("Denoise", selection: $denoiseAI) {
                    Text("Standard").tag(false)
                    Text("AI").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                if denoiseAI, film.denoiser != .ready {
                    aiOffer
                } else {
                    HStack(spacing: 8) {
                        Slider(value: $denoiseStrength, in: 10...100, step: 5)
                        Text(verbatim: "\(Int(denoiseStrength))").font(.caption.monospacedDigit()).frame(width: 26, alignment: .trailing)
                        Button(record.denoise > 0 ? "Redo" : "Denoise") {
                            editing.denoise(paths, strength: Int(denoiseStrength), ai: denoiseAI)
                        }
                    }
                }
                if record.denoise > 0 {
                    HStack {
                        Label(record.denoiseAI ? "AI denoised at \(record.denoise)" : "Denoised at \(record.denoise)", systemImage: "checkmark.circle.fill")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Remove") { change { $0.denoise = 0; $0.denoiseAI = false } }.buttonStyle(.link).font(.caption)
                    }
                }
            }
            if let problem = editing.denoiseProblem { ProblemLabel(text: problem) }
        }
        .controlSize(.small)
        .padding(.horizontal, 8)
        .padding(.top, 4)
        .onAppear {
            film.checkDenoiser()
            if record.denoise > 0 { denoiseStrength = Double(record.denoise); denoiseAI = record.denoiseAI }
        }
    }

    @ViewBuilder private var aiOffer: some View {
        switch film.denoiser {
        case .installing:
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: film.denoiserProgress)
                Text("Getting the AI denoiser…").font(.caption).foregroundStyle(.secondary)
            }
        case .failed(let message):
            ProblemLabel(text: message)
            Button("Try Again") { film.installDenoiser() }
        default:
            VStack(alignment: .leading, spacing: 6) {
                Text("A network trained on real camera noise, like Lightroom’s. Runs on this Mac’s GPU.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 12) {
                    Label("\(FilmEngine.denoiserDownloadMB) MB download", systemImage: "arrow.down.circle")
                    Label("\(FilmEngine.denoiserDiskMB) MB on disk", systemImage: "internaldrive")
                }
                .font(.caption2).foregroundStyle(.secondary)
                Button("Get AI Denoise", systemImage: "arrow.down") { film.installDenoiser() }
                    .buttonStyle(BrandButtonStyle(large: false))
            }
        }
    }

    private var presetsMenu: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(catalog.presets) { preset in
                    Button(preset.name) { change { $0.adjust = preset.adjust.keepingDecoder(of: $0.adjust); $0.filmOn = preset.filmOn; $0.film = preset.film } }
                }
                if !catalog.presets.isEmpty { Divider() }
                Button("Save as Preset…") { presetName = ""; naming = true }
                if !catalog.presets.isEmpty {
                    Menu("Delete") {
                        ForEach(catalog.presets) { preset in Button(preset.name) { catalog.deletePreset(preset.id) } }
                    }
                }
            } label: {
                Label("Presets", systemImage: "wand.and.stars")
            }
            .fixedSize()
        }
        .alert("Save Preset", isPresented: $naming) {
            TextField("Name", text: $presetName)
            Button("Save") {
                let name = presetName.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { catalog.savePreset(named: name, from: record) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Keeps these adjustments and the film, to use on other photos.")
        }
    }

    private func slider(_ title: LocalizedStringKey, _ path: WritableKeyPath<PhotoAdjustments, Double>, _ range: ClosedRange<Double>,
                        format: String = "%+.0f", label: String? = nil) -> some View {
        let value = record.adjust[keyPath: path]
        return HStack(spacing: 8) {
            Text(title).foregroundStyle(.secondary).lineLimit(1).frame(width: 84, alignment: .leading)
            Slider(value: Binding(get: { value }, set: { new in change { $0.adjust[keyPath: path] = new } }), in: range)
            Text(label ?? String(format: format, value)).font(.caption.monospacedDigit()).foregroundStyle(value == 0 ? .tertiary : .primary)
                .frame(width: label == nil ? 44 : 58, alignment: .trailing)
                .onTapGesture(count: 2) { change { $0.adjust[keyPath: path] = 0 } }
                .help("Double-click to reset")
        }
        .font(.callout)
        .controlSize(.small)
        .padding(.horizontal, 8)
        .frame(minHeight: 26)
    }
}

// MARK: - Details

/// What the camera wrote: the file, its size, the camera and lens, the exposure.
private struct PhotoDetails: View {
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
                .font(.caption)
                .padding(.horizontal, 8)
                .frame(minHeight: 20)
            }
        }
        .task(id: path) { lines = Self.read(path) }
    }

    static func read(_ path: String) -> [(String, String)] {
        let url = URL(fileURLWithPath: path)
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

    var body: some View {
        switch engine.state {
        case .notInstalled: offer
        case .installing: installing
        case .failed(let message):
            VStack(alignment: .leading, spacing: 10) {
                ProblemLabel(text: message)
                Button("Try Again") { engine.install() }.buttonStyle(BrandButtonStyle(large: false))
            }
            .padding(.horizontal, 8)
        case .ready: controls
        }
        credit
    }

    private var offer: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: "film.stack").font(.system(size: 28)).foregroundStyle(Design.Brand.gradient)
            Text("Real film, simulated").font(.title3.weight(.semibold))
            Text("spektrafilm develops your photo the way film does: the stock, the paper it’s printed on, grain and halation, from measured data. In darktable’s native version: quick.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 14) {
                Label("\(FilmEngine.downloadMB) MB download", systemImage: "arrow.down.circle")
                Label("\(FilmEngine.diskMB) MB on disk", systemImage: "internaldrive")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            Button("Download the Films", systemImage: "arrow.down") { engine.install() }
                .buttonStyle(BrandButtonStyle())
            Text("The film and paper data, checked as it downloads, kept in Pluck’s own folder. Remove it any time in Settings.")
                .font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: Design.Radius.card, style: .continuous).fill(Color.primary.opacity(0.05)))
        .padding(.horizontal, 6)
    }

    private var installing: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Downloading the films").font(.callout.weight(.semibold))
            ProgressView(value: engine.progress).progressViewStyle(.linear)
            HStack {
                Text(engine.stage)
                Spacer()
                Text(engine.progress, format: .percent.precision(.fractionLength(0))).monospacedDigit()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            Text("About \(FilmEngine.downloadMB) MB.").font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: Design.Radius.card, style: .continuous).fill(Color.primary.opacity(0.05)))
        .padding(.horizontal, 6)
    }

    private var credit: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Film modelling powered by spektrafilm by Andrea Volpato, in darktable’s native version.")
            HStack(spacing: 4) {
                Link("spektrafilm", destination: URL(string: "https://github.com/andreavolpato/spektrafilm")!)
                Text(verbatim: "·")
                Link("darktable", destination: URL(string: "https://github.com/darktable-org/darktable")!)
                Text(verbatim: "· GPLv3 · data CC BY-SA 4.0")
            }
        }
        .font(.caption2)
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
        default: return engine.schema[key]?.value ?? 0
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
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: Binding(get: { record.filmOn }, set: { on in change { $0.filmOn = on } })) {
                Label("Develop on Film", systemImage: "film").font(.callout.weight(.semibold))
            }
            .toggleStyle(.switch)
            .padding(.horizontal, 8)

            FoldSection(title: "Stock", key: "film-stock") {
                filmRow("Film") {
                    Picker("Film", selection: Binding(get: { record.film.film }, set: { id in
                        change { record in
                            record.film.film = id
                            // The paper the film is made for.
                            if let paper = engine.films.first(where: { $0.id == id })?.print, engine.papers.contains(where: { $0.id == paper }) {
                                record.film.paper = paper
                            }
                            // Slides and black and white reversal are looked at, not printed.
                            let film = engine.films.first { $0.id == id }
                            record.film.changed["scan_film"] = .number(film?.type == "positive" ? 1 : 0)
                            record.filmOn = true
                        }
                    })) {
                        Section("Colour Negative") { ForEach(engine.films.filter { $0.type == "negative" && $0.use != "cine" && $0.bw != true }) { Text($0.name).tag($0.id) } }
                        Section("Slide") { ForEach(engine.films.filter { $0.type == "positive" && $0.bw != true }) { Text($0.name).tag($0.id) } }
                        Section("Cinema") { ForEach(engine.films.filter { $0.use == "cine" && $0.type != "positive" && $0.bw != true }) { Text($0.name).tag($0.id) } }
                        Section("Black & White") { ForEach(engine.films.filter { $0.bw == true }) { Text($0.name).tag($0.id) } }
                    }
                    .labelsHidden()
                }
                if value("scan_film") < 0.5 {
                    filmRow("Paper") {
                        Picker("Paper", selection: Binding(get: { record.film.paper }, set: { id in change { $0.film.paper = id; $0.filmOn = true } })) {
                            ForEach(engine.papers) { Text($0.name).tag($0.id) }
                        }
                        .labelsHidden()
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
                    .buttonStyle(.link)
                Spacer()
            }
            .padding(.horizontal, 8)
        }
    }

    private func filmRow<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 8) {
            Text(title).foregroundStyle(.secondary).lineLimit(1).frame(width: 96, alignment: .leading)
            content().frame(maxWidth: .infinity, alignment: .trailing)
        }
        .font(.callout)
        .controlSize(.small)
        .padding(.horizontal, 8)
        .frame(minHeight: 26)
    }

    private func filmSlider(_ title: LocalizedStringKey, key: String, range: ClosedRange<Double>, format: String) -> some View {
        let current = value(key)
        return filmRow(title) {
            Slider(value: Binding(get: { current }, set: { set(key, $0) }), in: min(range.lowerBound, current)...max(range.upperBound, current))
            Text(String(format: format, current)).font(.caption.monospacedDigit())
                .foregroundStyle(record.film.changed[key] == nil ? .tertiary : .primary)
                .frame(width: 58, alignment: .trailing)
                .onTapGesture(count: 2) { change { $0.film.changed[key] = nil } }
                .help("Double-click to reset")
        }
    }

    private func filmToggle(_ title: LocalizedStringKey, key: String) -> some View {
        filmRow(title) {
            Toggle(title, isOn: Binding(get: { value(key) > 0.5 }, set: { set(key, $0 ? 1 : 0) }))
                .toggleStyle(.switch).controlSize(.mini).labelsHidden()
        }
    }

    /// Any other setting: a dial over darktable's range for it.
    @ViewBuilder private func advancedRow(_ key: String, _ setting: FilmEngine.Setting) -> some View {
        let name = FilmDial.words(key)
        switch setting.kind {
        case .flag:
            HStack(spacing: 8) {
                Text(name).font(.caption).foregroundStyle(record.film.changed[key] == nil ? .secondary : .primary).lineLimit(1)
                Spacer()
                Toggle(name, isOn: Binding(get: { value(key) > 0.5 }, set: { set(key, $0 ? 1 : 0) })).toggleStyle(.switch).controlSize(.mini).labelsHidden()
            }
            .padding(.horizontal, 8).frame(minHeight: 22)
        case .number, .choice:
            let current = value(key)
            HStack(spacing: 8) {
                Text(name).font(.caption).foregroundStyle(record.film.changed[key] == nil ? .secondary : .primary).lineLimit(1)
                    .frame(width: 120, alignment: .leading).help(key)
                Slider(value: Binding(get: { current }, set: { set(key, setting.kind == .choice ? $0.rounded() : $0) }), in: setting.min...setting.max)
                    .controlSize(.mini)
                Text(String(format: abs(current) < 10 ? "%.2f" : "%.0f", current)).font(.caption2.monospacedDigit())
                    .frame(width: 38, alignment: .trailing)
                    .onTapGesture(count: 2) { change { $0.film.changed[key] = nil } }
                    .help("Double-click to reset")
            }
            .padding(.horizontal, 8).frame(minHeight: 22)
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
                HStack(spacing: 4) {
                    title.font(.caption2.weight(.semibold)).textCase(.uppercase).foregroundStyle(.tertiary)
                    detail?.font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(open ? 90 : 0))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
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
    @AppStorage("photoExportFormat") private var format = PhotoRender.Format.jpeg
    @AppStorage("photoExportQuality") private var quality = 0.9
    @AppStorage("photoExportLongSide") private var longSide = 0
    @AppStorage("photoExportFolder") private var folderPath = ""
    @State private var editing = PhotoEditing.shared
    private var done: Int { editing.exportDone }
    private var running: Bool { editing.exporting }
    private var total: Int { editing.exportTotal }

    private var folder: URL {
        folderPath.isEmpty ? FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0].appendingPathComponent("Pluck", isDirectory: true)
            : URL(fileURLWithPath: folderPath, isDirectory: true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SidebarSection(title: Text("File")) {
                row("Format") {
                    Picker("Format", selection: $format) { ForEach(PhotoRender.Format.allCases) { Text($0.title).tag($0) } }.labelsHidden()
                }
                if format == .jpeg || format == .heic {
                    row("Quality") {
                        Slider(value: $quality, in: 0.5...1)
                        Text(quality, format: .percent.precision(.fractionLength(0))).font(.caption.monospacedDigit()).frame(width: 40)
                    }
                }
                row("Size") {
                    Picker("Size", selection: $longSide) {
                        Text("Full Size").tag(0)
                        Text("4096 px").tag(4096)
                        Text("2048 px").tag(2048)
                        Text("1080 px").tag(1080)
                    }
                    .labelsHidden()
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
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    export()
                } label: {
                    Label("Export ^[\(paths.count) Photo](inflect: true)", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
                }
                .buttonStyle(BrandButtonStyle())
                .disabled(running)
                if running {
                    ProgressView(value: Double(done), total: Double(max(total, 1))).controlSize(.small)
                    Text("\(done) of \(total)").font(.caption).foregroundStyle(.secondary)
                } else if let problem = editing.exportProblem {
                    Text(problem).font(.caption).foregroundStyle(.orange)
                } else if let lastFolder = editing.exportFolder {
                    Button("Show in Finder") { NSWorkspace.shared.open(lastFolder) }.buttonStyle(.link).font(.caption)
                }
                if paths.contains(where: { catalog.record($0).filmOn }) {
                    Text("Photos on film are developed at full size: that takes a while each.").font(.caption2).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 8)
        }
        .task {
            // Screenshots: -PluckScreenshotPhotoExport YES exports the selection straight away.
            if ScreenshotMode.scene == "photo", UserDefaults.standard.bool(forKey: "PluckScreenshotPhotoExport"), !running, done == 0 {
                try? await Task.sleep(for: .seconds(2))
                export()
            }
        }
    }

    private func row<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 8) {
            Text(title).foregroundStyle(.secondary).frame(width: 70, alignment: .leading)
            HStack(spacing: 6) { content() }.frame(maxWidth: .infinity, alignment: .trailing)
        }
        .font(.callout)
        .controlSize(.small)
        .padding(.horizontal, 8)
        .frame(minHeight: 26)
    }

    private func export() {
        let started = Date.now
        let targets = paths, folder = self.folder, format = self.format, quality = self.quality, longSide = self.longSide
        let editing = editing
        editing.exporting = true
        editing.exportDone = 0
        editing.exportTotal = targets.count
        editing.exportProblem = nil
        let records = Dictionary(uniqueKeysWithValues: targets.map { ($0, catalog.record($0)) })
        // Several at a time, each on its own film engine process (previews keep the first one).
        let lanes = min(FilmEngine.exportWorkers, targets.count)
        Task {
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            await withTaskGroup(of: (lane: Int, failure: String?).self) { group in
                var queue = targets[...]
                func next(_ lane: Int) {
                    guard let path = queue.popFirst() else { return }
                    group.addTask {
                        do {
                            _ = try await PhotoRender.export(path, record: records[path] ?? PhotoRecord(), to: folder, format: format,
                                                             quality: quality, longSide: longSide, worker: lane + 1)
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
            editing.exportFolder = folder
            if ScreenshotMode.scene != nil {
                // Tests: how long it took.
                try? "\(targets.count) photos in \(Int(Date.now.timeIntervalSince(started))) s".write(
                    to: folder.appendingPathComponent("export-time.txt"), atomically: true, encoding: .utf8)
            }
        }
    }
}
