import SwiftUI

/// One thin bar per part, when it comes in and for how long: drag a bar to move it, its end to
/// make it longer or shorter; click one to choose that part.
struct LogoTimingStrip: View {
    let animation: LogoAnimation
    let design: LogoAnimation.Design
    @Binding var edits: LogoDesignEdits
    @Binding var selected: Int?
    /// A drag in progress: which part, and how far (seconds) its start or end has moved.
    @State private var dragging: (part: Int, start: Double, end: Double)?

    private var rows: [(part: Int, span: ClosedRange<Double>)] {
        animation.elements.indices.compactMap { i in animation.span(of: i, in: design.spec).map { (i, $0) } }
            .sorted { $0.span.lowerBound < $1.span.lowerBound }
    }

    var body: some View {
        let rows = rows
        let total = max(design.spec.duration, 0.5) * 1.15
        let height: CGFloat = rows.count > 24 ? 3 : 5, gap: CGFloat = rows.count > 12 ? 2 : 5
        GeometryReader { geometry in
            let width = geometry.size.width
            VStack(alignment: .leading, spacing: gap) {
                ForEach(rows, id: \.part) { row in
                    let moved = dragging?.part == row.part ? dragging : nil
                    let start = row.span.lowerBound + (moved?.start ?? 0), end = row.span.upperBound + (moved?.end ?? 0)
                    ZStack(alignment: .trailing) {
                        Capsule()
                            .fill(selected == row.part ? AnyShapeStyle(LinearGradient(colors: [Design.Brand.pink, Design.Brand.violet], startPoint: .leading, endPoint: .trailing)) : AnyShapeStyle(Design.rgb(0x4A4A50)))
                        // The end, to drag for length.
                        Capsule().fill(.white.opacity(selected == row.part ? 0.9 : 0)).frame(width: 3)
                            .contentShape(.rect.inset(by: -6))
                            .gesture(DragGesture(minimumDistance: 1)
                                .onChanged { value in dragging = (row.part, 0, value.translation.width / width * total) }
                                .onEnded { value in commit(row, endShift: value.translation.width / width * total) })
                    }
                    .frame(width: max((end - start) / total * width, 6), height: height)
                    .offset(x: start / total * width)
                    .contentShape(.rect.inset(by: -2))
                    .onTapGesture { selected = selected == row.part ? nil : row.part }
                    .gesture(DragGesture(minimumDistance: 2)
                        .onChanged { value in
                            let shift = value.translation.width / width * total
                            dragging = (row.part, shift, shift)
                            selected = row.part
                        }
                        .onEnded { value in commit(row, startShift: value.translation.width / width * total) })
                }
            }
        }
        .frame(height: CGFloat(rows.count) * (height + gap) - gap)
        .help("When each part comes in. Drag a bar to move it, its end to make it quicker or slower; click one to change it.")
        .accessibilityLabel(String(localized: "Timing of the parts"))
    }

    private func commit(_ row: (part: Int, span: ClosedRange<Double>), startShift: Double = 0, endShift: Double = 0) {
        dragging = nil
        var edit = edits.parts[row.part] ?? .init()
        if startShift != 0 { edit.delay = ((edit.delay + startShift) * 100).rounded() / 100 }
        if endShift != 0 {
            let length = max(row.span.upperBound - row.span.lowerBound, 0.05)
            edit.length = min(max(edit.length * (length + endShift) / length, 0.25), 4)
        }
        edits.parts[row.part] = edit.isEmpty ? nil : edit
    }
}

/// The part chosen in the preview, as the inspector's first fold: when it comes in, how it
/// moves, from where and how it eases (layout board ToolLogo).
struct LogoPartFold: View {
    let animation: LogoAnimation
    let part: Int
    @Binding var edits: LogoDesignEdits

    private var edit: Binding<LogoDesignEdits.PartEdit> {
        Binding { edits.parts[part] ?? .init() } set: { edits.parts[part] = $0.isEmpty ? nil : $0 }
    }

    private var isHero: Bool { animation.profile.hero.contains(part) }

    /// What the part is, in a word or two.
    private var name: Text {
        let element = animation.elements[part]
        if isHero { return Text("The hero") }
        if element.spark { return Text("A dot") }
        switch animation.profile.roles[part] {
        case .symbol: return Text("Part of the symbol")
        case .plate: return Text("A plate")
        case .tagline: return Text("A tagline letter")
        case .wordmark: return Text("A letter")
        }
    }

    private var asDesigned: String { String(localized: "As designed") }

    var body: some View {
        LogoKitFold(Text("Part · ") + name, key: "logoFoldPart") {
            StudioField(label: "Order") {
                Button { edit.wrappedValue.delay = (edit.wrappedValue.delay - 0.1).rounded(toPlaces: 2) } label: {
                    Label("Earlier", systemImage: "arrow.left")
                }
                .help("Comes in a tenth of a second sooner")
                Button { edit.wrappedValue.delay = (edit.wrappedValue.delay + 0.1).rounded(toPlaces: 2) } label: {
                    HStack(spacing: 6) { Text("Later"); Image(systemName: "arrow.right") }
                }
                .help("Comes in a tenth of a second later")
            }
            .buttonStyle(StudioFlatButtonStyle())
            StudioField(label: "Motion") {
                if isHero {
                    LogoKitMenu(title: "Motion", shown: edits.hero?.label ?? asDesigned, selection: $edits.hero) {
                        Text("As Designed").tag(LogoAnimation.HeroMove?.none)
                        Divider()
                        ForEach(animation.heroMoves().map(\.move)) { Text($0.label).tag(LogoAnimation.HeroMove?.some($0)) }
                    }
                    .help("The hero's move: the ones that suit this logo")
                } else {
                    LogoKitMenu(title: "Motion", shown: edit.wrappedValue.motion?.label ?? asDesigned, selection: edit.motion) {
                        Text("As Designed").tag(LogoDesignEdits.Motion?.none)
                        Divider()
                        ForEach(LogoDesignEdits.Motion.allCases) { Text($0.label).tag(LogoDesignEdits.Motion?.some($0)).help($0.help) }
                    }
                    .help("How it comes in")
                }
            }
            StudioField(label: "Enter from") {
                LogoKitMenu(title: "Enter from", shown: edit.wrappedValue.from?.label ?? asDesigned, selection: edit.from) {
                    Text("As Designed").tag(LogoDesignEdits.Direction?.none)
                    Divider()
                    ForEach(LogoDesignEdits.Direction.allCases) { Text($0.label).tag(LogoDesignEdits.Direction?.some($0)) }
                }
                .help("The side it moves in from")
            }
            StudioField(label: "Ease") {
                LogoKitMenu(title: "Ease", shown: edit.wrappedValue.ease?.label ?? asDesigned, selection: edit.ease) {
                    Text("As Designed").tag(LogoDesignEdits.Ease?.none)
                    Divider()
                    ForEach(LogoDesignEdits.Ease.allCases) { Text($0.label).tag(LogoDesignEdits.Ease?.some($0)).help($0.help) }
                }
                .help("How it settles into place")
            }
            if !(edits.parts[part]?.isEmpty ?? true) || (isHero && edits.hero != nil) {
                HStack {
                    Spacer()
                    Button("Back to As Designed") {
                        edits.parts[part] = nil
                        if isHero { edits.hero = nil }
                    }
                    .buttonStyle(.plain)
                    .font(Design.Studio.body)
                    .foregroundStyle(Design.Studio.textQuiet)
                }
                .frame(height: 28)
            }
        }
    }
}

private extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let scale = pow(10, Double(places))
        return (self * scale).rounded() / scale
    }
}

extension LogoAnimation {
    /// The part under a point of a preview of `canvas` size (points from its top left), if any:
    /// the smallest part whose box holds it.
    func part(at point: CGPoint, canvas: CGSize) -> Int? {
        let rect = logoRect(canvas: canvas)
        let fit = rect.width / size.width
        // The preview's top left; parts' boxes are from the logo's top left.
        let x = (point.x - rect.minX) / fit, y = (point.y - (canvas.height - rect.maxY)) / fit
        return elements.indices.filter { elements[$0].box.insetBy(dx: -3, dy: -3).contains(CGPoint(x: x, y: y)) }
            .min { elements[$0].box.width * elements[$0].box.height < elements[$1].box.width * elements[$1].box.height }
    }

    /// A part's box in a preview of `canvas` size (points from its top left).
    func box(of part: Int, canvas: CGSize) -> CGRect {
        let rect = logoRect(canvas: canvas)
        let fit = rect.width / size.width
        let b = elements[part].box
        return CGRect(x: rect.minX + b.minX * fit, y: canvas.height - rect.maxY + b.minY * fit, width: b.width * fit, height: b.height * fit)
    }
}

// MARK: - Inspector pieces shared by Logo Animator and Brand Pack (layout boards ToolLogo, ToolBrand)

/// An inspector section: its name (14 medium) and a chevron, opens and closes; remembered.
struct LogoKitFold<Content: View>: View {
    let title: Text
    var help = ""
    var accessory: AnyView?
    @ViewBuilder var content: Content
    @AppStorage private var isOpen: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(_ title: Text, key: String, open: Bool = true, help: String = "", accessory: AnyView? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.help = help
        self.accessory = accessory
        self.content = content()
        _isOpen = AppStorage(wrappedValue: open, key)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                if reduceMotion { isOpen.toggle() } else { withAnimation(.snappy(duration: 0.2)) { isOpen.toggle() } }
            } label: {
                HStack(spacing: 8) {
                    title.font(Design.Studio.sectionTitle).foregroundStyle(Design.Studio.text).lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Design.Studio.textFaint)
                }
                .frame(height: 30)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help(Text(verbatim: help))
            .accessibilityHint(Text(isOpen ? "Closes the section" : "Opens the section"))
            .overlay(alignment: .trailing) { accessory.padding(.trailing, 20) }
            if isOpen { content }
        }
    }
}

/// A menu as on the boards: what's chosen and a small chevron, no box; the choices as a list.
struct LogoKitMenu<Value: Hashable, Options: View>: View {
    let title: LocalizedStringKey
    let shown: String
    @Binding var selection: Value
    @ViewBuilder var options: Options

    var body: some View {
        Menu {
            Picker(selection: $selection) { options } label: { Text(title) }
                .pickerStyle(.inline)
                .labelsHidden()
        } label: {
            HStack(spacing: 5) {
                Text(verbatim: shown).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(Design.Studio.textQuiet)
            }
            .font(Design.Studio.body)
            .foregroundStyle(Design.Studio.text)
            .frame(height: 28)
            .contentShape(.rect)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(Text(title))
        .accessibilityValue(Text(verbatim: shown))
    }
}

/// StudioSegmented's look, stretched to the inspector's width (Feel, Output).
struct LogoKitSegmented<Value: Hashable>: View {
    let options: [(value: Value, title: String)]
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options.indices, id: \.self) { index in
                let option = options[index]
                let on = option.value == selection
                Button { selection = option.value } label: {
                    Text(verbatim: option.title)
                        .font(Design.Studio.body)
                        .foregroundStyle(on ? Design.Studio.text : Design.Studio.textQuiet)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .frame(height: 24)
                        .background(on ? Design.Studio.line : .clear, in: .rect(cornerRadius: 6, style: .continuous))
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Design.Studio.backdrop, in: .rect(cornerRadius: 8, style: .continuous))
    }
}

/// A 44 × 26 colour swatch; clicking it opens the colour panel (the system well, unseen, on top).
struct LogoKitWell: View {
    let title: LocalizedStringKey
    @Binding var colour: Color

    var body: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(colour)
            .overlay { RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Design.Studio.line, lineWidth: 1) }
            .frame(width: 44, height: 26)
            .overlay {
                ColorPicker(title, selection: $colour, supportsOpacity: false)
                    .labelsHidden()
                    .frame(width: 44, height: 26)
                    .opacity(0.02)
            }
    }
}

/// What was made, and a way to show it.
struct LogoKitDone: View {
    let text: Text
    var file: URL?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Design.Studio.good)
            text.foregroundStyle(Design.Studio.text).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
            if let file {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file]) }
                    .buttonStyle(.plain)
                    .foregroundStyle(Design.Studio.textQuiet)
            }
        }
        .font(Design.Studio.body)
    }
}

/// What went wrong, in one calm line.
struct LogoKitProblem: View {
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Design.Studio.warn)
            Text(verbatim: text).foregroundStyle(Design.Studio.textQuiet).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .font(Design.Studio.body)
    }
}
