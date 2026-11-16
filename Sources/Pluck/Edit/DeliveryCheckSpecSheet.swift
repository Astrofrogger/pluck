import SwiftUI

/// A delivery spec, edited: a preset is saved as a copy, one's own is changed or deleted.
struct DeliveryCheckSpecSheet: View {
    @State var spec: DeliveryCheck.Spec
    /// The saved spec's id (nil when deleted).
    let done: (String?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var rates = ""
    @State private var codecs = ""

    /// Colour tags (primaries, transfer, matrix) by name.
    private static let colours: [(name: String, tags: [String]?)] = [
        (String(localized: "Any"), nil), ("Rec. 709", ["bt709", "bt709", "bt709"]), ("Rec. 601", ["smpte170m", "smpte170m", "smpte170m"]),
        ("Rec. 2020 PQ", ["bt2020", "smpte2084", "bt2020nc"]), ("Rec. 2020 HLG", ["bt2020", "arib-std-b67", "bt2020nc"]),
    ]
    private static let aspects: [Double?] = [nil, 16.0 / 9, 9.0 / 16, 1, 4.0 / 5, 4.0 / 3]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                StudioTile(symbol: "slider.horizontal.3", size: 32)
                Text(spec.builtIn ? "New Spec" : "Spec").font(Design.Studio.sectionTitle)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    section(nil) { text("Name", $spec.name) }
                    section("Picture") {
                        row("Shape") {
                            Picker("Shape", selection: $spec.aspect) {
                                ForEach(Self.aspects, id: \.self) { aspect in
                                    Text(aspect.map(DeliveryCheck.Spec.aspectText) ?? String(localized: "Any")).tag(aspect)
                                }
                            }
                            .labelsHidden().fixedSize()
                        }
                        row("Size") { number("1920", int: $spec.width); Text("×").foregroundStyle(Design.Studio.textQuiet); number("1080", int: $spec.height) }
                        row("Long side at least") { number("1920", int: $spec.minLongSide) }
                        row("Frame rates") { text("25, 50", $rates) }
                        row("Codecs") { text("h264, prores", $codecs) }
                        row("Bitrate, Mb/s") { number("min", $spec.minBitrate); Text("–").foregroundStyle(Design.Studio.textQuiet); number("max", $spec.maxBitrate) }
                        row("Colour") {
                            Picker("Colour", selection: Binding(get: { colourIndex }, set: { setColour($0) })) {
                                ForEach(Self.colours.indices, id: \.self) { Text(Self.colours[$0].name).tag($0) }
                                if colourIndex == -1 { Text(verbatim: [spec.primaries, spec.transfer, spec.matrix].map { $0 ?? "–" }.joined(separator: " / ")).tag(-1) }
                            }
                            .labelsHidden().fixedSize()
                        }
                    }
                    section("Sound") {
                        row("Sample rate, Hz") { number("48000", int: $spec.sampleRate) }
                        row("Channels") { number("2", int: $spec.channels) }
                        row("Loudness, LUFS") { number("-23", $spec.loudness); Text("±").foregroundStyle(Design.Studio.textQuiet); number("1", value: $spec.loudnessTolerance) }
                        row("True peak, dBTP") { number("-1", value: $spec.truePeak) }
                    }
                    section("Text safe area, %") {
                        HStack(spacing: 8) {
                            margin("Left", get: { $0.minX }, set: { rect, v in CGRect(x: v, y: rect.minY, width: rect.maxX - v, height: rect.height) })
                            margin("Right", get: { 1 - $0.maxX }, set: { rect, v in CGRect(x: rect.minX, y: rect.minY, width: 1 - v - rect.minX, height: rect.height) })
                            margin("Top", get: { 1 - $0.maxY }, set: { rect, v in CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: 1 - v - rect.minY) })
                            margin("Bottom", get: { $0.minY }, set: { rect, v in CGRect(x: rect.minX, y: v, width: rect.width, height: rect.maxY - v) })
                        }
                    }
                    section(nil) { StudioSwitchRow(title: "Strict: anything off is a problem", isOn: $spec.strict) }
                }
            }
            .scrollIndicators(.never)
            .frame(minHeight: 460)

            HStack(spacing: 8) {
                if !spec.builtIn {
                    Button("Delete Spec", role: .destructive) {
                        DeliveryCheck.delete(spec)
                        done(nil)
                        dismiss()
                    }
                    .buttonStyle(.plain).font(Design.Studio.body).foregroundStyle(Design.Studio.bad)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .buttonStyle(StudioFlatButtonStyle(height: 32))
                    .keyboardShortcut(.cancelAction)
                Button(spec.builtIn ? "Save as New" : "Done") {
                    // "23,976" is one rate (decimal comma, only for the fractional broadcast rates); "24,25" is two rates.
                    let decimal = rates.replacingOccurrences(of: #"\b(23|29|47|59|98|119),(976|97|952|94|88)\b"#, with: "$1.$2", options: .regularExpression)
                    spec.frameRates = decimal.split(whereSeparator: { ", ;".contains($0) }).compactMap { Double($0) }
                    spec.codecs = codecs.split(whereSeparator: { ", ;".contains($0) }).map { $0.lowercased() }
                    done(DeliveryCheck.save(spec).id)
                    dismiss()
                }
                .buttonStyle(StudioFlatButtonStyle(prominent: true, height: 32))
                .keyboardShortcut(.defaultAction)
                .disabled(spec.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 520)
        .background(Design.Studio.panel)
        .preferredColorScheme(.dark)
        .tint(Design.Brand.pink)
        .onAppear {
            rates = spec.frameRates.map { String(format: "%g", $0) }.joined(separator: ", ")
            codecs = spec.codecs.joined(separator: ", ")
            if spec.builtIn { spec.name = String(localized: "\(spec.shortTitle) copy") }
        }
    }

    private var colourIndex: Int {
        let tags = [spec.primaries, spec.transfer, spec.matrix]
        if tags.allSatisfy({ $0 == nil }) { return 0 }
        return Self.colours.firstIndex { $0.tags.map { $0 == tags.compactMap { $0 } } ?? false } ?? -1
    }

    private func setColour(_ index: Int) {
        guard Self.colours.indices.contains(index) else { return }
        let tags = Self.colours[index].tags
        spec.primaries = tags?[0]
        spec.transfer = tags?[1]
        spec.matrix = tags?[2]
    }

    private func section<Content: View>(_ title: LocalizedStringKey?, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title { Text(title).font(Design.Studio.body).foregroundStyle(Design.Studio.textQuiet) }
            VStack(alignment: .leading, spacing: 8) { content() }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .studioBox()
        }
    }

    private func row<Content: View>(_ label: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 8) {
            Text(label).font(Design.Studio.body).foregroundStyle(Design.Studio.textQuiet).frame(width: 140, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
    }

    private func styled<V: View>(_ field: V, width: CGFloat?) -> some View {
        field
            .textFieldStyle(.plain)
            .font(Design.Studio.body)
            .padding(.horizontal, 10)
            .frame(width: width, height: 30)
            .background(Design.Studio.raised, in: .rect(cornerRadius: Design.Studio.controlRadius, style: .continuous))
    }

    private func text(_ hint: LocalizedStringKey, _ value: Binding<String>) -> some View {
        styled(TextField(hint, text: value, prompt: Text(hint).foregroundStyle(Design.Studio.textFaint)), width: nil)
    }

    private func number(_ hint: String, _ value: Binding<Double?>) -> some View {
        styled(TextField(hint, value: value, format: .number.grouping(.never), prompt: Text(verbatim: hint).foregroundStyle(Design.Studio.textFaint)), width: 80)
    }

    private func number(_ hint: String, value: Binding<Double>) -> some View {
        styled(TextField(hint, value: value, format: .number.grouping(.never)), width: 80)
    }

    private func number(_ hint: String, int value: Binding<Int?>) -> some View {
        styled(TextField(hint, value: value, format: .number.grouping(.never), prompt: Text(verbatim: hint).foregroundStyle(Design.Studio.textFaint)), width: 80)
    }

    /// One side of the safe area, in percent of the picture.
    private func margin(_ label: LocalizedStringKey, get: @escaping (CGRect) -> CGFloat, set: @escaping (CGRect, CGFloat) -> CGRect) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet)
            styled(TextField(label, value: Binding(get: { Double((get(spec.safeArea) * 100).rounded()) },
                                                  set: { spec.safeArea = set(spec.safeArea, CGFloat(min(max($0, 0), 45)) / 100) }),
                             format: .number.grouping(.never)), width: 70)
        }
    }
}
