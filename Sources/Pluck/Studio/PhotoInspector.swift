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
                        change { $0.adjust = copied.adjust; $0.film = copied.film; $0.filmOn = copied.filmOn }
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
        VStack(alignment: .leading, spacing: 14) {
            presets
            SidebarSection(title: Text("Light")) {
                slider("Exposure", \.exposure, -4...4, format: "%+.2f")
                slider("Contrast", \.contrast, -100...100)
                slider("Highlights", \.highlights, -100...100)
                slider("Shadows", \.shadows, -100...100)
                slider("Whites", \.whites, -100...100)
                slider("Blacks", \.blacks, -100...100)
            }
            SidebarSection(title: Text("Colour")) {
                slider("Temperature", \.temperature, -100...100)
                slider("Tint", \.tint, -100...100)
                slider("Vibrance", \.vibrance, -100...100)
                slider("Saturation", \.saturation, -100...100)
            }
            SidebarSection(title: Text("Curves")) {
                CurvesEditor(curves: record.adjust.curves) { curves in change { $0.adjust.curves = curves } }
            }
            SidebarSection(title: Text("Colour Wheels")) {
                ColorWheelsEditor(wheels: record.adjust.wheels) { wheels in change { $0.adjust.wheels = wheels } }
            }
            SidebarSection(title: Text("Detail")) {
                slider("Clarity", \.clarity, -100...100)
                slider("Sharpen", \.sharpen, 0...100)
                slider("Noise", \.noise, 0...100)
                slider("Vignette", \.vignette, -100...100)
            }
            denoise
            SidebarSection(title: Text("Crop")) {
                HStack {
                    Text("Aspect").foregroundStyle(.secondary).frame(width: 84, alignment: .leading)
                    Picker("Aspect", selection: Binding(get: { record.adjust.crop }, set: { value in
                        change { $0.adjust.crop = value; $0.adjust.cropRect = nil }
                        if value != .original { editing.cropping = true }
                    })) {
                        ForEach(PhotoAdjustments.Crop.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
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

    @State private var denoiseStrength = 50.0
    @State private var film = FilmEngine.shared

    /// Denoise: a slower, better noise reduction at full size, done once and kept.
    private var denoise: some View {
        SidebarSection(title: Text("Denoise")) {
            let busy = paths.filter(editing.denoising.contains).count
            VStack(alignment: .leading, spacing: 6) {
                if film.state != .ready {
                    Text("Uses the photo engine. Get it in the Film tab.").font(.caption).foregroundStyle(.secondary)
                } else if busy > 0 {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Removing noise from ^[\(busy) photo](inflect: true)…").font(.callout).foregroundStyle(.secondary)
                    }
                } else {
                    HStack(spacing: 8) {
                        Slider(value: $denoiseStrength, in: 10...100, step: 5).controlSize(.small)
                        Text(verbatim: "\(Int(denoiseStrength))").font(.caption.monospacedDigit()).frame(width: 26, alignment: .trailing)
                        Button(record.denoise > 0 ? "Redo" : "Denoise") { editing.denoise(paths, strength: Int(denoiseStrength)) }
                            .controlSize(.small)
                    }
                    if record.denoise > 0 {
                        HStack {
                            Label("Denoised at \(record.denoise)", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button("Remove") { change { $0.denoise = 0 } }.buttonStyle(.link).font(.caption)
                        }
                    }
                }
                if let problem = editing.denoiseProblem { ProblemLabel(text: problem) }
            }
            .padding(.horizontal, 8)
        }
        .onAppear { if record.denoise > 0 { denoiseStrength = Double(record.denoise) } }
    }

    private var presets: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(catalog.presets) { preset in
                    Button(preset.name) { change { $0.adjust = preset.adjust; $0.filmOn = preset.filmOn; $0.film = preset.film } }
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
            Spacer()
        }
        .controlSize(.small)
        .padding(.horizontal, 8)
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
                        format: String = "%+.0f") -> some View {
        let value = record.adjust[keyPath: path]
        return HStack(spacing: 8) {
            Text(title).foregroundStyle(.secondary).lineLimit(1).frame(width: 84, alignment: .leading)
            Slider(value: Binding(get: { value }, set: { new in change { $0.adjust[keyPath: path] = new } }), in: range)
            Text(String(format: format, value)).font(.caption.monospacedDigit()).foregroundStyle(value == 0 ? .tertiary : .primary)
                .frame(width: 44, alignment: .trailing)
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
            Text("spektrafilm develops your photo the way film does: the stock, the paper it’s printed on, grain and halation, from measured data.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 14) {
                Label("\(FilmEngine.downloadMB) MB download", systemImage: "arrow.down.circle")
                Label("\(FilmEngine.diskMB) MB on disk", systemImage: "internaldrive")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            Button("Download Film Engine", systemImage: "arrow.down") { engine.install() }
                .buttonStyle(BrandButtonStyle())
            Text("Downloaded into Pluck’s own folder and run on this Mac. Remove it any time in Settings.")
                .font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: Design.Radius.card, style: .continuous).fill(Color.primary.opacity(0.05)))
        .padding(.horizontal, 6)
    }

    private var installing: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Downloading the film engine").font(.callout.weight(.semibold))
            ProgressView(value: engine.progress).progressViewStyle(.linear)
            HStack {
                Text(engine.stage)
                Spacer()
                Text(engine.progress, format: .percent.precision(.fractionLength(0))).monospacedDigit()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            Text("About \(FilmEngine.downloadMB) MB. You can keep working meanwhile.").font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: Design.Radius.card, style: .continuous).fill(Color.primary.opacity(0.05)))
        .padding(.horizontal, 6)
    }

    private var credit: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Film modelling powered by spektrafilm by Andrea Volpato.")
            HStack(spacing: 4) {
                Link("spektrafilm", destination: URL(string: "https://github.com/andreavolpato/spektrafilm")!)
                Text(verbatim: "· GPLv3 · profiles CC BY-SA 4.0")
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

    private func number(_ key: String, fallback: Double) -> Double {
        if case .number(let value) = record.film.changed[key] { return value }
        if case .number(let value) = engine.schema[key] { return value }
        return fallback
    }

    private func flag(_ key: String, fallback: Bool) -> Bool {
        if case .flag(let value) = record.film.changed[key] { return value }
        if case .flag(let value) = engine.schema[key] { return value }
        return fallback
    }

    private func set(_ key: String, _ value: SettingValue) {
        change { $0.film.changed[key] = value }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle(isOn: Binding(get: { record.filmOn }, set: { on in change { $0.filmOn = on } })) {
                Label("Develop on Film", systemImage: "film").font(.callout.weight(.semibold))
            }
            .toggleStyle(.switch)
            .padding(.horizontal, 8)

            SidebarSection(title: Text("Stock")) {
                filmRow("Film") {
                    Picker("Film", selection: Binding(get: { record.film.film }, set: { id in
                        change { record in
                            record.film.film = id
                            // The paper the film is made for.
                            if let paper = engine.films.first(where: { $0.id == id })?.print, engine.papers.contains(where: { $0.id == paper }) {
                                record.film.paper = paper
                            }
                            record.filmOn = true
                        }
                    })) {
                        Section("Colour Negative") { ForEach(engine.films.filter { $0.type == "negative" && $0.use != "cine" }) { Text($0.name).tag($0.id) } }
                        Section("Slide") { ForEach(engine.films.filter { $0.type == "positive" }) { Text($0.name).tag($0.id) } }
                        Section("Cinema") { ForEach(engine.films.filter { $0.use == "cine" && $0.type != "positive" }) { Text($0.name).tag($0.id) } }
                    }
                    .labelsHidden()
                }
                filmRow("Paper") {
                    Picker("Paper", selection: Binding(get: { record.film.paper }, set: { id in change { $0.film.paper = id; $0.filmOn = true } })) {
                        ForEach(engine.papers) { Text($0.name).tag($0.id) }
                    }
                    .labelsHidden()
                }
            }
            SidebarSection(title: Text("Camera")) {
                filmSlider("Exposure", key: "camera.exposure_compensation_ev", range: -3...3, fallback: 0, format: "%+.1f EV")
                filmToggle("Auto Exposure", key: "camera.auto_exposure", fallback: true)
                filmRow("Format") {
                    Picker("Format", selection: Binding(get: { number("camera.film_format_mm", fallback: 35) }, set: { set("camera.film_format_mm", .number($0)) })) {
                        Text("35 mm").tag(35.0)
                        Text("Medium (6×6)").tag(60.0)
                        Text("Large (4×5)").tag(100.0)
                    }
                    .labelsHidden()
                }
                .help("Bigger film: finer grain")
            }
            SidebarSection(title: Text("Print")) {
                filmSlider("Print Exposure", key: "enlarger.print_exposure", range: 0.4...2.5, fallback: 1, format: "%.2f")
                filmSlider("Warm / Cool", key: "enlarger.y_filter_shift", range: -30...30, fallback: 0, format: "%+.0f")
                filmSlider("Magenta / Green", key: "enlarger.m_filter_shift", range: -30...30, fallback: 0, format: "%+.0f")
                filmSlider("Pre-flash", key: "enlarger.preflash_exposure", range: 0...0.2, fallback: 0, format: "%.2f")
            }
            SidebarSection(title: Text("Film Effects")) {
                filmToggle("Grain", key: "film_render.grain.active", fallback: true)
                filmSlider("Grain Size", key: "film_render.grain.agx_particle_area_um2", range: 0.05...1.2, fallback: 0.2, format: "%.2f")
                filmToggle("Halation", key: "film_render.halation.active", fallback: true)
                filmSlider("Halation", key: "film_render.halation.halation_amount", range: 0...4, fallback: 1, format: "%.1f")
                filmSlider("Glow", key: "film_render.halation.scatter_amount", range: 0...4, fallback: 1, format: "%.1f")
                filmSlider("Couplers", key: "film_render.dir_couplers.amount", range: 0...2, fallback: 1, format: "%.2f")
                    .help("The film’s colour couplers: more saturation and local contrast")
                filmToggle("Diffusion Filter", key: "camera.diffusion_filter.active", fallback: false)
                filmSlider("Diffusion", key: "camera.diffusion_filter.strength", range: 0...2, fallback: 0.5, format: "%.2f")
            }
            Fold(title: Text("Advanced"), detail: Text(verbatim: "\(engine.schema.count)"), open: $advancedOpen) {
                ForEach(engine.schema.keys.sorted(), id: \.self) { key in advancedRow(key) }
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

    private func filmSlider(_ title: LocalizedStringKey, key: String, range: ClosedRange<Double>, fallback: Double, format: String) -> some View {
        let value = number(key, fallback: fallback)
        return filmRow(title) {
            Slider(value: Binding(get: { value }, set: { set(key, .number($0)) }), in: range)
            Text(String(format: format, value)).font(.caption.monospacedDigit())
                .foregroundStyle(record.film.changed[key] == nil ? .tertiary : .primary)
                .frame(width: 54, alignment: .trailing)
                .onTapGesture(count: 2) { change { $0.film.changed[key] = nil } }
                .help("Double-click to reset")
        }
    }

    private func filmToggle(_ title: LocalizedStringKey, key: String, fallback: Bool) -> some View {
        filmRow(title) {
            Toggle(title, isOn: Binding(get: { flag(key, fallback: fallback) }, set: { set(key, .flag($0)) }))
                .toggleStyle(.switch).controlSize(.mini).labelsHidden()
        }
    }

    /// Any of spektrafilm's settings, by its name.
    @ViewBuilder private func advancedRow(_ key: String) -> some View {
        let current = record.film.changed[key] ?? engine.schema[key]
        HStack(spacing: 6) {
            Text(key).font(.caption2.monospaced()).foregroundStyle(record.film.changed[key] == nil ? .secondary : .primary)
                .lineLimit(1).truncationMode(.head)
                .help(key)
            Spacer(minLength: 4)
            switch current {
            case .flag(let value):
                Toggle(key, isOn: Binding(get: { value }, set: { set(key, .flag($0)) })).toggleStyle(.switch).controlSize(.mini).labelsHidden()
            case .number(let value):
                TextField(key, value: Binding(get: { value }, set: { set(key, .number($0)) }), format: .number.precision(.significantDigits(1...6)))
                    .textFieldStyle(.roundedBorder).controlSize(.mini).frame(width: 70).labelsHidden()
            case .numbers(let values):
                TextField(key, text: Binding(get: { values.map { String(format: "%g", $0) }.joined(separator: ", ") }, set: { text in
                    let parsed = text.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                    if parsed.count == values.count { set(key, .numbers(parsed)) }
                }))
                .textFieldStyle(.roundedBorder).controlSize(.mini).frame(width: 110).labelsHidden()
            case .text(let value):
                TextField(key, text: Binding(get: { value }, set: { set(key, .text($0)) }))
                    .textFieldStyle(.roundedBorder).controlSize(.mini).frame(width: 110).labelsHidden()
            case nil:
                EmptyView()
            }
        }
        .padding(.horizontal, 8)
        .frame(minHeight: 22)
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
