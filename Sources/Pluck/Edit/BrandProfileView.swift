import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Choosing the brand profile a check runs against: none, a saved one, a new one, or one from a file.
struct BrandProfilePicker: View {
    @Binding var selection: UUID?
    @State private var store = BrandProfiles.shared
    @State private var editing: BrandProfile?
    @State private var problem: String?

    var body: some View {
        Menu {
            Button { selection = nil } label: { checked(selection == nil, Text("No brand profile")) }
            ForEach(store.all) { profile in
                Button { selection = profile.id } label: { checked(selection == profile.id, Text(verbatim: profile.name)) }
            }
            Divider()
            Button("New Brand Profile…") { editing = BrandProfile(name: String(localized: "New brand")) }
            if let current = store.profile(selection) {
                Button("Edit “\(current.name)”…") { editing = current }
            }
            Button("Import Brand Profile…") { importProfile() }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "seal").font(.system(size: 11))
                Text(verbatim: store.profile(selection)?.name ?? String(localized: "No brand"))
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
            }
            .font(Design.Studio.body)
            .foregroundStyle(Design.Studio.textQuiet)
            .padding(.horizontal, 8)
            .frame(height: 28)
            .contentShape(.rect)
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .fixedSize()
        .help("Brand profile")
        .sheet(item: $editing) { profile in
            BrandProfileEditor(profile: profile) { saved in selection = saved?.id }
        }
        .alert(problem ?? "", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {}
    }

    private func checked(_ on: Bool, _ title: Text) -> some View {
        if on { return AnyView(Label { title } icon: { Image(systemName: "checkmark") }) }
        return AnyView(title)
    }

    private func importProfile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.prompt = String(localized: "Import")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { selection = try store.importFile(url).id } catch { problem = String(localized: "That file isn’t a brand profile.") }
    }
}

/// A brand profile's rules: the logos, where the logo goes (drawn on a frame), when it shows,
/// its clear space and colour, the palette and the texts. Filled by hand, by measuring an
/// approved video, or from a brand book's suggestions.
struct BrandProfileEditor: View {
    @State var profile: BrandProfile
    /// The saved profile, or nil when it was deleted.
    var done: (BrandProfile?) -> Void = { _ in }
    @Environment(\.dismiss) private var dismiss
    @State private var sizeIndex = 0
    @State private var thumbnails: [UUID: NSImage] = [:]
    /// The approved video's frame, behind the placement drawing.
    @State private var frame: NSImage?
    @State private var measured: BrandCheck.Measurement?
    @State private var suggestions: [BrandBookImport.Suggestion]?
    @State private var working = false
    @State private var problem: String?
    @State private var newColour = ""
    @State private var newForbidden = ""
    @State private var newFont = ""

    private static let sizes: [(Int, Int)] = [(1920, 1080), (3840, 2160), (1080, 1920), (1080, 1080), (1080, 1350)]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                TextField("Name", text: $profile.name)
                    .textFieldStyle(.plain)
                    .font(Design.Studio.sectionTitle)
                Spacer(minLength: 0)
                if working { PlumSpinner().frame(width: 16, height: 16) }
                Button("From approved video…", systemImage: "film") { measureApproved() }
                    .buttonStyle(StudioFlatButtonStyle())
                    .disabled(working)
                Button("From brand book…", systemImage: "book") { readBook() }
                    .buttonStyle(StudioFlatButtonStyle())
                    .disabled(working)
            }
            .padding(16)
            HStack(alignment: .top, spacing: Design.Studio.panelGap) {
                VStack(alignment: .leading, spacing: Design.Studio.sectionGap) {
                    logos
                    preview
                    if let problem {
                        Label(problem, systemImage: "exclamationmark.triangle").font(Design.Studio.body).foregroundStyle(Design.Studio.bad)
                    }
                    Spacer(minLength: 0)
                }
                .frame(width: 360)
                ScrollView { inspector.padding(.trailing, 4) }
                    .scrollIndicators(.never)
            }
            .padding(.horizontal, 16)
            HStack(spacing: 8) {
                Button("Export…") { export() }.buttonStyle(StudioFlatButtonStyle())
                if BrandProfiles.shared.profile(profile.id) != nil {
                    Button("Delete") {
                        BrandProfiles.shared.delete(profile)
                        done(nil)
                        dismiss()
                    }
                    .buttonStyle(StudioFlatButtonStyle())
                }
                Spacer(minLength: 0)
                Button("Cancel") { dismiss() }.buttonStyle(StudioFlatButtonStyle()).keyboardShortcut(.cancelAction)
                Button("Save") { save() }.buttonStyle(StudioFlatButtonStyle(prominent: true, height: 32)).keyboardShortcut(.defaultAction)
                    .disabled(profile.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(16)
        }
        .foregroundStyle(Design.Studio.text)
        .frame(width: 820, height: 640)
        .background(Design.Studio.panel)
        .task { refreshThumbnails() }
        .alert("Use these measurements?", isPresented: Binding(get: { measured != nil }, set: { if !$0 { measured = nil } }), presenting: measured) { m in
            Button("Use") { use(m) }
            Button("Cancel", role: .cancel) {}
        } message: { m in Text(verbatim: summary(m)) }
        .sheet(isPresented: Binding(get: { suggestions != nil }, set: { if !$0 { suggestions = nil } })) { bookSheet }
    }

    // MARK: - Logos and the drawing

    private var logos: some View {
        HStack(spacing: 8) {
            ForEach(profile.logos) { logo in
                ZStack {
                    RoundedRectangle(cornerRadius: Design.Studio.controlRadius, style: .continuous).fill(Design.Studio.backdrop)
                    if let image = thumbnails[logo.id] { Image(nsImage: image).resizable().scaledToFit().padding(6) }
                }
                .frame(width: 64, height: 44)
                .overlay {
                    if placement?.logoID == logo.id || (placement?.logoID == nil && logo.id == profile.logos.first?.id) {
                        RoundedRectangle(cornerRadius: Design.Studio.controlRadius, style: .continuous).strokeBorder(Design.Brand.pink, lineWidth: 1)
                    }
                }
                .onTapGesture { if profile.placements.indices.contains(sizeIndex) { profile.placements[sizeIndex].logoID = logo.id } }
                .contextMenu { Button("Remove") { profile.logos.removeAll { $0.id == logo.id } } }
                .help(Text(verbatim: logo.fileName))
            }
            Button { addLogo() } label: {
                Image(systemName: "plus").font(.system(size: 12)).foregroundStyle(Design.Studio.textQuiet)
                    .frame(width: 44, height: 44)
                    .overlay {
                        RoundedRectangle(cornerRadius: Design.Studio.controlRadius, style: .continuous)
                            .strokeBorder(Design.Studio.line, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    }
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help("Add a logo file (PNG, SVG or PDF)")
        }
    }

    private var placement: BrandProfile.Placement? {
        profile.placements.indices.contains(sizeIndex) ? profile.placements[sizeIndex] : nil
    }

    /// The output picture with the logo where the rule puts it, its box and its clear space.
    private var preview: some View {
        let p = placement ?? BrandProfile.Placement()
        let logo = profile.logo(for: p).flatMap { thumbnails[$0.id] }
        let aspect = Double(p.referenceWidth) / Double(max(p.referenceHeight, 1))
        return ZStack {
            Rectangle().fill(Design.Studio.backdrop)
            if let frame { Image(nsImage: frame).resizable() }
            GeometryReader { geometry in
                let k = geometry.size.width / Double(max(p.referenceWidth, 1))
                let logoAspect = logo.map { $0.size.width / max($0.size.height, 1) } ?? 3
                let rect = p.rect(in: CGSize(width: Double(p.referenceWidth), height: Double(p.referenceHeight)), logoAspect: logoAspect)
                let box = CGRect(x: rect.minX * k, y: rect.minY * k, width: rect.width * k, height: rect.height * k)
                let space = profile.clearSpace.pixels(logoWidth: rect.width, scale: 1) * k
                if placement != nil {
                    if let logo { Image(nsImage: logo).resizable().frame(width: box.width, height: box.height).position(x: box.midX, y: box.midY).opacity(frame == nil ? 1 : 0.6) }
                    Rectangle().strokeBorder(Design.Brand.pink, lineWidth: 1).frame(width: box.width, height: box.height).position(x: box.midX, y: box.midY)
                    if space > 0 {
                        Rectangle().strokeBorder(Design.Studio.warn, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                            .frame(width: box.width + 2 * space, height: box.height + 2 * space).position(x: box.midX, y: box.midY)
                    }
                }
            }
        }
        .aspectRatio(aspect, contentMode: .fit)
        .frame(maxWidth: 360)
        .clipShape(.rect(cornerRadius: 10, style: .continuous))
        .overlay {
            if placement == nil {
                Text("Add an output size").font(Design.Studio.body).foregroundStyle(Design.Studio.textQuiet)
            }
        }
    }

    // MARK: - The rules

    private var inspector: some View {
        VStack(alignment: .leading, spacing: Design.Studio.sectionGap) {
            LogoKitFold(Text("Placement"), key: "brandRuleFoldPlacement") {
                HStack(spacing: 6) {
                    if !profile.placements.isEmpty {
                        StudioSegmented(options: profile.placements.indices.map { ($0, LocalizedStringKey(String(profile.placements[$0].referenceWidth) + "×" + String(profile.placements[$0].referenceHeight))) },
                                        selection: $sizeIndex)
                    }
                    Menu {
                        ForEach(Self.sizes.indices, id: \.self) { i in
                            let size = Self.sizes[i]
                            Button { addSize(size.0, size.1) } label: { Text(verbatim: "\(size.0)×\(size.1)") }
                        }
                    } label: { Image(systemName: "plus").font(.system(size: 11)).frame(width: 24, height: 24).contentShape(.rect) }
                    .menuStyle(.button).menuIndicator(.hidden).buttonStyle(.plain).fixedSize()
                    .help("Add an output size")
                    if placement != nil {
                        Button { profile.placements.remove(at: sizeIndex); sizeIndex = max(sizeIndex - 1, 0) } label: {
                            Image(systemName: "minus").font(.system(size: 11)).frame(width: 24, height: 24).contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .help("Remove this size")
                    }
                }
                if profile.placements.indices.contains(sizeIndex) {
                    let p = $profile.placements[sizeIndex]
                    StudioField(label: "From") {
                        Picker("From", selection: p.anchor) {
                            ForEach(BrandProfile.Anchor.allCases) { Text($0.label).tag($0) }
                        }
                        .labelsHidden().fixedSize()
                    }
                    number("Across", p.x, unit: "px")
                    number("Down", p.y, unit: "px")
                    number("Width", p.width, unit: "px")
                    number("Off by", p.tolerance, unit: "px")
                    number("Size off", p.scaleTolerance, unit: "%")
                }
            }
            LogoKitFold(Text("When"), key: "brandRuleFoldWhen") {
                StudioSegmented(options: BrandProfile.Timing.Mode.allCases.map { ($0, LocalizedStringKey($0.label)) }, selection: $profile.timing.mode, fill: true)
                if profile.timing.mode == .endCard { number("Last", $profile.timing.endCard, unit: "s") }
                if profile.timing.mode == .ranges {
                    ForEach(profile.timing.ranges.indices, id: \.self) { i in
                        HStack(spacing: 6) {
                            numberBox($profile.timing.ranges[i].start, unit: "s")
                            Text(verbatim: "–").foregroundStyle(Design.Studio.textQuiet)
                            numberBox($profile.timing.ranges[i].end, unit: "s")
                            Spacer(minLength: 0)
                            removeButton { profile.timing.ranges.remove(at: i) }
                        }
                    }
                    StudioDashedButton(title: "Add a time", height: 30) { profile.timing.ranges.append(.init(start: 0, end: 5)) }
                }
                number("Not before", $profile.timing.notInFirst, unit: "s")
            }
            LogoKitFold(Text("Clear space and colour"), key: "brandRuleFoldSpace") {
                HStack(spacing: 6) {
                    number("Clear space", $profile.clearSpace.amount, unit: "")
                    StudioSegmented(options: [(false, "px"), (true, "%")], selection: $profile.clearSpace.percent)
                }
                number("Smallest", $profile.minimumWidth, unit: "px")
                StudioField(label: "Logo colour") {
                    if let rgb = profile.logoColour.flatMap(BrandProfile.rgb(hex:)) { swatch(rgb) }
                    textBox(Binding(get: { profile.logoColour ?? "" }, set: { profile.logoColour = $0.isEmpty ? nil : $0 }), prompt: "Its own")
                        .frame(width: 90)
                }
                number("Colour off", $profile.colourTolerance, unit: "ΔE")
            }
            LogoKitFold(Text("Palette"), key: "brandRuleFoldPalette") {
                FlowRows(items: profile.palette) { item in
                    HStack(spacing: 5) {
                        if let rgb = item.hex.flatMap(BrandProfile.rgb(hex:)) { swatch(rgb) }
                        Text(verbatim: item.hex ?? item.name).font(Design.Studio.hint)
                    }
                    .padding(.horizontal, 8).frame(height: 22)
                    .background(Design.Studio.raised, in: .capsule)
                    .contextMenu { Button("Remove") { profile.palette.removeAll { $0.id == item.id } } }
                    .help(Text(verbatim: item.name))
                }
                textBox($newColour, prompt: "#RRGGBB")
                    .onSubmit {
                        if let rgb = BrandProfile.rgb(hex: newColour) { profile.palette.append(.init(hex: BrandProfile.hex(rgb))); newColour = "" }
                    }
                StudioSwitchRow(title: "Flag other colours", isOn: $profile.checkPalette)
            }
            LogoKitFold(Text("Text"), key: "brandRuleFoldText") {
                ForEach($profile.requiredTexts) { $item in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            textBox($item.text, prompt: "Must show")
                            removeButton { profile.requiredTexts.removeAll { $0.id == item.id } }
                        }
                        HStack(spacing: 6) {
                            Picker("When", selection: $item.when) { ForEach(BrandProfile.RequiredText.When.allCases) { Text($0.label).tag($0) } }
                                .labelsHidden().fixedSize()
                            Picker("Where", selection: $item.area) { ForEach(BrandProfile.RequiredText.Area.allCases) { Text($0.label).tag($0) } }
                                .labelsHidden().fixedSize()
                        }
                        .font(Design.Studio.body)
                    }
                }
                StudioDashedButton(title: "Add a text that must show", height: 30) { profile.requiredTexts.append(.init(text: "")) }
                tags($profile.forbiddenTexts, new: $newForbidden, prompt: "Must not show")
            }
            LogoKitFold(Text("More"), key: "brandRuleFoldMore", open: false) {
                tags($profile.fonts, new: $newFont, prompt: "Fonts")
                StudioField(label: "Delivery spec") {
                    textBox(Binding(get: { profile.deliverySpec ?? "" }, set: { profile.deliverySpec = $0.isEmpty ? nil : $0 }), prompt: "None")
                        .frame(width: 160)
                }
            }
        }
    }

    // MARK: - Small controls

    private func number(_ label: LocalizedStringKey, _ value: Binding<Double>, unit: String) -> some View {
        StudioField(label: label) { numberBox(value, unit: unit) }
    }

    private func numberBox(_ value: Binding<Double>, unit: String) -> some View {
        HStack(spacing: 4) {
            TextField("", value: value, format: .number.precision(.fractionLength(0...1)))
                .textFieldStyle(.plain).multilineTextAlignment(.trailing).monospacedDigit()
                .frame(width: 56)
            if !unit.isEmpty { Text(verbatim: unit).foregroundStyle(Design.Studio.textQuiet) }
        }
        .font(Design.Studio.body)
        .padding(.horizontal, 8).frame(height: 26)
        .background(Design.Studio.backdrop, in: .rect(cornerRadius: Design.Studio.controlRadius, style: .continuous))
    }

    private func textBox(_ text: Binding<String>, prompt: LocalizedStringKey) -> some View {
        TextField("", text: text, prompt: Text(prompt).foregroundStyle(Design.Studio.textFaint))
            .textFieldStyle(.plain)
            .font(Design.Studio.body)
            .padding(.horizontal, 8).frame(height: 26)
            .background(Design.Studio.backdrop, in: .rect(cornerRadius: Design.Studio.controlRadius, style: .continuous))
    }

    private func swatch(_ rgb: SIMD3<Double>) -> some View {
        Circle().fill(Color(red: rgb.x, green: rgb.y, blue: rgb.z)).frame(width: 12, height: 12)
            .overlay { Circle().strokeBorder(Design.Studio.line, lineWidth: 1) }
    }

    private func removeButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)).foregroundStyle(Design.Studio.textQuiet).frame(width: 20, height: 20).contentShape(.rect) }
            .buttonStyle(.plain)
            .help("Remove")
    }

    /// Words as chips, and a box to add one.
    private func tags(_ list: Binding<[String]>, new: Binding<String>, prompt: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            FlowRows(items: list.wrappedValue.map { Tag(text: $0) }) { tag in
                HStack(spacing: 4) {
                    Text(verbatim: tag.text).font(Design.Studio.hint)
                    removeButton { list.wrappedValue.removeAll { $0 == tag.text } }
                }
                .padding(.leading, 8).frame(height: 22)
                .background(Design.Studio.raised, in: .capsule)
            }
            textBox(new, prompt: prompt)
                .onSubmit {
                    let text = new.wrappedValue.trimmingCharacters(in: .whitespaces)
                    if !text.isEmpty, !list.wrappedValue.contains(text) { list.wrappedValue.append(text) }
                    new.wrappedValue = ""
                }
        }
    }

    private struct Tag: Identifiable { let text: String; var id: String { text } }

    // MARK: - Actions

    private func refreshThumbnails() {
        for logo in profile.logos where thumbnails[logo.id] == nil {
            if let image = BrandProfile.image(of: logo, width: 400) {
                thumbnails[logo.id] = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
            }
        }
    }

    private func addLogo() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .svg, .pdf, .jpeg, .tiff]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard let data = try? Data(contentsOf: url) else { continue }
            let logo = BrandProfile.Logo(fileName: url.lastPathComponent, data: data)
            guard BrandProfile.image(of: logo) != nil else { problem = String(localized: "Pluck can’t read \(url.lastPathComponent)."); continue }
            profile.logos.append(logo)
        }
        refreshThumbnails()
    }

    private func addSize(_ width: Int, _ height: Int) {
        if let existing = profile.placements.firstIndex(where: { $0.referenceWidth == width && $0.referenceHeight == height }) { sizeIndex = existing; return }
        var p = placement ?? BrandProfile.Placement()
        // The same place, scaled to the new width.
        let k = Double(width) / Double(max(p.referenceWidth, 1))
        p.id = UUID(); p.referenceWidth = width; p.referenceHeight = height
        p.x *= k; p.y *= k; p.width *= k
        profile.placements.append(p)
        sizeIndex = profile.placements.count - 1
    }

    private func measureApproved() {
        guard let logo = profile.logo(for: placement ?? BrandProfile.Placement()) else { problem = String(localized: "Add the logo first."); return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .image]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        working = true
        problem = nil
        Task {
            let result = await BrandCheck.measure(file: url, logo: logo)
            var picture = BrandCheck.still(url)
            if picture == nil, let video = await BrandCheck.Video(url) { picture = await video.frame(video.frameCount - 1) }
            working = false
            guard let result else { problem = String(localized: "The logo isn’t in that file."); return }
            frame = picture.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
            measured = result
        }
    }

    private func summary(_ m: BrandCheck.Measurement) -> String {
        let p = m.placement
        var lines = [String(localized: "\(p.anchor.label): \(BrandCheck.pixels(p.x)) px across, \(BrandCheck.pixels(p.y)) px down, \(BrandCheck.pixels(p.width)) px wide (\(p.referenceWidth)×\(p.referenceHeight))."),
                     String(localized: "Colour \(m.colour).")]
        if let timing = m.timing {
            switch timing.mode {
            case .endCard: lines.append(String(localized: "End card: the last \(BrandCheck.pixels(timing.endCard)) s."))
            case .ranges: lines.append(String(localized: "On screen at set times."))
            case .always: lines.append(String(localized: "On screen all the time."))
            }
        }
        return lines.joined(separator: "\n")
    }

    private func use(_ m: BrandCheck.Measurement) {
        var p = m.placement
        if let i = profile.placements.firstIndex(where: { $0.referenceWidth == p.referenceWidth && $0.referenceHeight == p.referenceHeight }) {
            p.id = profile.placements[i].id
            p.tolerance = profile.placements[i].tolerance
            p.scaleTolerance = profile.placements[i].scaleTolerance
            profile.placements[i] = p
            sizeIndex = i
        } else {
            profile.placements.append(p)
            sizeIndex = profile.placements.count - 1
        }
        if let timing = m.timing {
            profile.timing.mode = timing.mode
            profile.timing.endCard = timing.endCard
            profile.timing.ranges = timing.ranges
        }
        profile.logoColour = m.colour
    }

    private func readBook() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        working = true
        Task {
            let found = await Task.detached { BrandBookImport.read(url) }.value
            working = false
            if found.isEmpty { problem = String(localized: "Nothing to use was found in that brand book.") } else { suggestions = found }
        }
    }

    private var bookSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("From the brand book").font(Design.Studio.sectionTitle)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Binding(get: { suggestions ?? [] }, set: { suggestions = $0 })) { $item in
                        HStack(spacing: 10) {
                            Toggle("", isOn: $item.chosen).toggleStyle(StudioSwitchStyle()).labelsHidden()
                            if case .logo(let logo) = item.kind, let image = BrandProfile.image(of: logo, width: 120) {
                                Image(nsImage: NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height)))
                                    .resizable().scaledToFit().frame(width: 48, height: 28)
                            }
                            if case .colour(let swatch) = item.kind, let rgb = swatch.hex.flatMap(BrandProfile.rgb(hex:)) { self.swatch(rgb) }
                            VStack(alignment: .leading, spacing: 1) {
                                Text(verbatim: item.label).font(Design.Studio.body)
                                Text(verbatim: item.source).font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }
                        .frame(minHeight: 34)
                    }
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { suggestions = nil }.buttonStyle(StudioFlatButtonStyle()).keyboardShortcut(.cancelAction)
                Button("Add") {
                    BrandBookImport.apply(suggestions ?? [], to: &profile)
                    suggestions = nil
                    refreshThumbnails()
                }
                .buttonStyle(StudioFlatButtonStyle(prominent: true, height: 32)).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480, height: 460)
        .foregroundStyle(Design.Studio.text)
        .background(Design.Studio.panel)
    }

    private func save() {
        do {
            try BrandProfiles.shared.save(profile)
            done(profile)
            dismiss()
        } catch {
            problem = String(localized: "The profile couldn’t be saved.")
        }
    }

    private func export() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = profile.name + ".json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try BrandProfiles.encoded(profile).write(to: url, options: .atomic) } catch { problem = String(localized: "The profile couldn’t be saved.") }
    }
}

/// Small things in rows that wrap.
private struct FlowRows<Item: Identifiable, Content: View>: View {
    let items: [Item]
    @ViewBuilder var content: (Item) -> Content

    var body: some View {
        WrapLayout(spacing: 6) { ForEach(items) { content($0) } }
    }
}

private struct WrapLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 320
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += row + spacing; row = 0 }
            x += size.width + spacing; row = max(row, size.height)
        }
        return CGSize(width: width, height: subviews.isEmpty ? 0 : y + row)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX { x = bounds.minX; y += row + spacing; row = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += size.width + spacing; row = max(row, size.height)
        }
    }
}
