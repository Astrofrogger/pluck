#if STUDIO
import SwiftUI

/// The Editor's Subtitles tab: how they look (font, weight, size, colour, outline or box, shadow,
/// italics and capitals, where they sit), the names to spell right, and the lines themselves,
/// each with its words and its timing. The picked line is the one lit on the timeline.
struct EditorSubtitlePanel<Model: FileEditing>: View {
    @Bindable var model: Model
    /// Makes the lines again from the transcript (nil without one).
    let remake: (() -> Void)?
    @AppStorage("subtitleStyleOpen") private var styleOpen = true
    @AppStorage("subtitleNamesOpen") private var namesOpen = false
    @State private var scrolled: UUID?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    Fold(title: Text("Style"), open: $styleOpen) { styleControls }
                    Fold(title: Text("Names"), detail: Glossary.shared.terms.isEmpty ? nil : Text(verbatim: "\(Glossary.shared.terms.count)"),
                         open: $namesOpen) {
                        GlossaryEditor { fixNames() }
                    }
                    SidebarSection(title: Text("Lines")) {
                        ForEach($model.subtitles) { $cue in
                            SubtitleLine(model: model, cue: $cue)
                                .id(cue.id)
                        }
                    }
                    .padding(.top, 6)
                }
                .scrollTargetLayout()
                .padding(.horizontal, 6)
                .padding(.bottom, 12)
            }
            .scrollPosition(id: $scrolled, anchor: .center)
            .onChange(of: model.subtitle(at: model.time)?.id) { _, id in
                if model.isPlaying, let id { withAnimation { scrolled = id } }
            }
            .onChange(of: model.selectedSubtitle) { _, id in
                if let id, !model.isPlaying { withAnimation { scrolled = id } }
            }
        }
        .onChange(of: model.subtitleStyle) { model.saveSubtitles() }
        .onChange(of: model.showSubtitles) { model.saveSubtitles() }
        .task(id: model.subtitles.count) {
            // Screenshots: -PluckScreenshotPickLine <n> picks that line.
            if ScreenshotMode.scene != nil, UserDefaults.standard.object(forKey: "PluckScreenshotPickLine") != nil, case let n = UserDefaults.standard.integer(forKey: "PluckScreenshotPickLine"),
               model.subtitles.indices.contains(n) {
                model.selectedSubtitle = model.subtitles[n].id
                model.seek(to: model.subtitles[n].start + 0.05)
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Toggle("Show", isOn: $model.showSubtitles)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .help("Show them on the picture and burn them into the export")
            Spacer()
            Button { model.addSubtitle(at: model.time) } label: { Label("Add Line", systemImage: "plus") }
                .buttonStyle(BrandButtonStyle(large: false))
                .help("A new line at the playhead (or split the line that's there)")
            Menu {
                Button("Export Subtitles…") {
                    SubtitleSaver.save(model.subtitles, name: model.file.deletingPathExtension().lastPathComponent)
                }
                Divider()
                Button("Fix Names in Every Line") { fixNames() }
                    .disabled(Glossary.shared.terms.isEmpty)
                if let remake {
                    Divider()
                    Button("Start Over from the Transcript", role: .destructive, action: remake)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func fixNames() {
        for index in model.subtitles.indices {
            model.subtitles[index].text = Glossary.correct(model.subtitles[index].text, terms: Glossary.shared.terms)
        }
        model.saveSubtitles()
    }

    // MARK: - Style

    private var styleControls: some View { SubtitleStyleEditor(style: $model.subtitleStyle) }
}

/// How subtitles look: font, weight, size, colour, outline or box, shadow, italics, capitals
/// and where they sit. The same for a file's subtitles and a project's.
struct SubtitleStyleEditor: View {
    @Binding var style: SubtitleStyle

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            row("Font") {
                Picker("Font", selection: $style.font) {
                    ForEach(fonts, id: \.self) { Text($0).font(.custom($0, size: 13)).tag($0) }
                }
            }
            row("Weight") {
                Picker("Weight", selection: $style.weight) {
                    ForEach(SubtitleStyle.weights, id: \.value) { Text($0.title).tag($0.value) }
                }
            }
            row("Size") {
                Slider(value: $style.scale, in: 0.4...2.5)
                Text(verbatim: "\(Int((style.scale * 100).rounded()))%")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 36, alignment: .trailing)
            }
            row("Colour") {
                HStack(spacing: 5) {
                    ForEach(SubtitleStyle.swatches, id: \.self) { hex in
                        Swatch(color: SubtitleStyle.color(hex), on: style.color == hex) { style.color = hex }
                    }
                    ColorPicker("Colour", selection: colour(\.color), supportsOpacity: false)
                }
            }
            row("Behind") {
                Picker("Behind", selection: $style.box) {
                    Text("Outline").tag(false)
                    Text("Box").tag(true)
                }
                .pickerStyle(.segmented)
            }
            if style.box {
                row("Box") {
                    Slider(value: $style.boxOpacity, in: 0.1...1)
                    ColorPicker("Box", selection: colour(\.boxColor), supportsOpacity: false)
                }
                .help("How solid the box is, and its colour")
            } else {
                row("Outline") {
                    Slider(value: $style.outline, in: 0...8)
                    ColorPicker("Outline", selection: colour(\.outlineColor), supportsOpacity: false)
                }
                .help("How thick the outline is, and its colour")
            }
            row("Shadow") {
                Slider(value: $style.shadow, in: 0...8)
            }
            row("Extras") {
                HStack(spacing: 4) {
                    Chip(text: Text("Italic").italic(), on: style.italic) { style.italic.toggle() }
                    Chip(text: Text("CAPS"), on: style.uppercase) { style.uppercase.toggle() }
                    Spacer(minLength: 0)
                }
            }
            row("Place") {
                HStack(spacing: 4) {
                    Chip(text: Text("Top"), on: style.y < 0.3) { place(0.1) }
                    Chip(text: Text("Middle"), on: (0.3...0.7).contains(style.y)) { place(0.5) }
                    Chip(text: Text("Bottom"), on: style.y > 0.7) { place(0.88) }
                    Spacer(minLength: 0)
                }
            }
            .help("Or drag them on the picture")
        }
        .padding(.bottom, 6)
    }

    private var fonts: [String] {
        let list = SubtitleStyle.fonts
        return list.contains(style.font) ? list : [style.font] + list
    }

    private func place(_ y: Double) {
        style.x = 0.5
        style.y = y
    }

    private func colour(_ path: WritableKeyPath<SubtitleStyle, String>) -> Binding<Color> {
        Binding(get: { SubtitleStyle.color(style[keyPath: path]) },
                set: { style[keyPath: path] = SubtitleStyle.hex($0) })
    }

    /// A setting's name on the left, its controls on the right.
    private func row<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 8) {
            Text(title).foregroundStyle(.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true).frame(width: 84, alignment: .leading)
            HStack(spacing: 6) { content() }
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .font(.callout)
        .controlSize(.small)
        .padding(.horizontal, 8)
        .frame(minHeight: 28)
    }
}

// MARK: - A line

/// One subtitle line: its time and words; picked, its timing to adjust and what to do with it.
private struct SubtitleLine<Model: FileEditing>: View {
    @Bindable var model: Model
    @Binding var cue: SubtitleCue

    private var picked: Bool { model.selectedSubtitle == cue.id }
    private var playing: Bool { model.subtitle(at: model.time)?.id == cue.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 6) {
                Text(verbatim: "\(Self.time(cue.start))")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(picked ? .primary : .tertiary)
                    .frame(width: 44, alignment: .leading)
                    .padding(.top, 2)
                TextField("", text: $cue.text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.callout)
                    .lineLimit(1...4)
                    .onChange(of: cue.text) { model.saveSubtitles() }
            }
            if picked { timing }
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 6)
        .background {
            RoundedRectangle(cornerRadius: Design.Radius.small, style: .continuous)
                .fill(picked ? AnyShapeStyle(Design.Brand.gradient.opacity(0.22))
                      : AnyShapeStyle(Color.accentColor.opacity(playing ? 0.12 : 0)))
        }
        .overlay {
            if picked {
                RoundedRectangle(cornerRadius: Design.Radius.small, style: .continuous).strokeBorder(Design.Brand.gradient.opacity(0.7))
            }
        }
        .contentShape(.rect)
        .onTapGesture {
            model.selectedSubtitle = cue.id
            model.seek(to: cue.start + 0.01)
        }
    }

    /// Start and end, a frame or a tenth at a time or at the playhead; split, join, delete.
    private var timing: some View {
        VStack(alignment: .leading, spacing: 4) {
            edge(Text("Start"), cue.start,
                 nudge: { model.setSubtitleStart(cue.id, to: cue.start + $0) },
                 here: { model.setSubtitleStart(cue.id, to: model.time) })
            edge(Text("End"), cue.end,
                 nudge: { model.setSubtitleEnd(cue.id, to: cue.end + $0) },
                 here: { model.setSubtitleEnd(cue.id, to: model.time) })
            HStack(spacing: 4) {
                Chip(text: Text("Split"), on: false) { model.splitSubtitle(cue.id, at: model.time) }
                    .help("Split this line at the playhead")
                Chip(text: Text("Join Next"), on: false) { model.mergeSubtitleWithNext(cue.id) }
                    .help("Join this line with the one after it")
                Spacer(minLength: 0)
                Button { model.deleteSubtitle(cue.id) } label: { Image(systemName: "trash") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Delete this line")
            }
        }
        .padding(.leading, 50)
    }

    private func edge(_ title: Text, _ value: Double, nudge: @escaping (Double) -> Void, here: @escaping () -> Void) -> some View {
        HStack(spacing: 4) {
            title.font(.caption).foregroundStyle(.secondary).frame(width: 34, alignment: .leading)
            Button { nudge(-0.1); model.saveSubtitles() } label: { Image(systemName: "minus") }
                .help("A tenth of a second earlier")
            Text(verbatim: Self.time(value))
                .font(.caption.monospacedDigit())
                .frame(width: 54)
            Button { nudge(0.1); model.saveSubtitles() } label: { Image(systemName: "plus") }
                .help("A tenth of a second later")
            Button { here(); model.saveSubtitles() } label: { Image(systemName: "arrow.down.to.line") }
                .help("To the playhead")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .font(.caption)
    }

    /// "1:02.40": minutes, seconds and hundredths.
    static func time(_ seconds: Double) -> String {
        let hundredths = Int((max(seconds, 0) * 100).rounded())
        return String(format: "%d:%02d.%02d", hundredths / 6000, hundredths / 100 % 60, hundredths % 100)
    }
}

// MARK: - Names

/// The glossary: names local AI should spell right, added by typing and removed with ×.
struct GlossaryEditor: View {
    var fixTitle: LocalizedStringKey = "Fix Names in Every Line"
    /// Applies the names to what's there already.
    var fix: (() -> Void)?
    @State private var glossary = Glossary.shared
    @State private var typed = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Add names: Anna Berg, Northwind…", text: $typed)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .onSubmit {
                    glossary.add(typed)
                    typed = ""
                }
            if !glossary.terms.isEmpty {
                FlowLayout(spacing: 4) {
                    ForEach(glossary.terms, id: \.self) { term in
                        HStack(spacing: 4) {
                            Text(term).lineLimit(1)
                            Button { glossary.remove(term) } label: { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }
                                .buttonStyle(.plain)
                                .accessibilityLabel(Text("Remove \(term)"))
                        }
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Design.Brand.gradient.opacity(0.25)))
                        .overlay(Capsule().strokeBorder(Design.Brand.violet.opacity(0.4)))
                    }
                }
                if let fix {
                    Button(fixTitle, action: fix)
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }
            Text("Used for every transcript and subtitle.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 6)
    }
}

// MARK: - Small parts

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
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.tertiary)
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

private struct Swatch: View {
    let color: Color
    let on: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Circle().fill(color)
                .overlay(Circle().strokeBorder(.separator))
                .overlay(Circle().strokeBorder(Design.Brand.gradient, lineWidth: 2).padding(-3).opacity(on ? 1 : 0))
                .frame(width: 15, height: 15)
        }
        .buttonStyle(.plain)
    }
}

private struct Chip: View {
    let text: Text
    let on: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            text.font(.caption.weight(.medium))
                .foregroundStyle(on ? Color.white : .primary)
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background {
                    Capsule().fill(on ? AnyShapeStyle(Design.Brand.gradient) : AnyShapeStyle(Color.primary.opacity(hovering ? 0.12 : 0.07)))
                }
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Lays its views out in rows, wrapping to the next row when one is full.
struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += row + spacing; row = 0 }
            x += size.width + spacing
            row = max(row, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: min(widest, width), height: y + row)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX { x = bounds.minX; y += row + spacing; row = 0 }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            row = max(row, size.height)
        }
    }
}
#endif
