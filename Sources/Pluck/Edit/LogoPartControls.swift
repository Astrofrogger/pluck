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
        let height: CGFloat = rows.count > 24 ? 3 : 5
        GeometryReader { geometry in
            let width = geometry.size.width
            VStack(alignment: .leading, spacing: 2) {
                ForEach(rows, id: \.part) { row in
                    let moved = dragging?.part == row.part ? dragging : nil
                    let start = row.span.lowerBound + (moved?.start ?? 0), end = row.span.upperBound + (moved?.end ?? 0)
                    ZStack(alignment: .trailing) {
                        Capsule()
                            .fill(selected == row.part ? AnyShapeStyle(Design.Brand.gradient) : AnyShapeStyle(Color.secondary.opacity(0.45)))
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
        .frame(height: CGFloat(rows.count) * (height + 2))
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

/// The part chosen in the preview: when it comes in, from where, how it moves and eases.
struct LogoPartCard: View {
    let animation: LogoAnimation
    let part: Int
    @Binding var edits: LogoDesignEdits
    let close: () -> Void

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

    var body: some View {
        Card {
            CardHeader(symbol: "square.on.circle", title: Text("Part"), subtitle: name) {
                Button("Done", action: close)
                    .buttonStyle(GlassCapsuleButtonStyle())
            }
            CardField(label: Text("Order")) {
                HStack(spacing: Design.Spacing.controls) {
                    Button("Earlier", systemImage: "arrow.left") { edit.wrappedValue.delay = (edit.wrappedValue.delay - 0.1).rounded(toPlaces: 2) }
                        .help("Comes in a tenth of a second sooner")
                    Button("Later", systemImage: "arrow.right") { edit.wrappedValue.delay = (edit.wrappedValue.delay + 0.1).rounded(toPlaces: 2) }
                        .help("Comes in a tenth of a second later")
                }
                .buttonStyle(GlassCapsuleButtonStyle())
            }
            CardField(label: Text("Enter from")) {
                Picker("Enter from", selection: edit.from) {
                    Text("As Designed").tag(LogoDesignEdits.Direction?.none)
                    Divider()
                    ForEach(LogoDesignEdits.Direction.allCases) { Text($0.label).tag(LogoDesignEdits.Direction?.some($0)) }
                }
                .labelsHidden()
                .fixedSize()
                .help("The side it moves in from")
            }
            CardField(label: Text("Motion")) {
                if isHero {
                    Picker("Motion", selection: $edits.hero) {
                        Text("As Designed").tag(LogoAnimation.HeroMove?.none)
                        Divider()
                        ForEach(animation.heroMoves().map(\.move)) { Text($0.label).tag(LogoAnimation.HeroMove?.some($0)) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .help("The hero's move: the ones that suit this logo")
                } else {
                    Picker("Motion", selection: edit.motion) {
                        Text("As Designed").tag(LogoDesignEdits.Motion?.none)
                        Divider()
                        ForEach(LogoDesignEdits.Motion.allCases) { Text($0.label).tag(LogoDesignEdits.Motion?.some($0)).help($0.help) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .help("How it comes in")
                }
            }
            CardField(label: Text("Ease")) {
                Picker("Ease", selection: edit.ease) {
                    Text("As Designed").tag(LogoDesignEdits.Ease?.none)
                    Divider()
                    ForEach(LogoDesignEdits.Ease.allCases) { Text($0.label).tag(LogoDesignEdits.Ease?.some($0)).help($0.help) }
                }
                .labelsHidden()
                .fixedSize()
                .help("How it settles into place")
            }
            if !(edits.parts[part]?.isEmpty ?? true) || (isHero && edits.hero != nil) {
                Button("Back to As Designed") {
                    edits.parts[part] = nil
                    if isHero { edits.hero = nil }
                }
                .buttonStyle(.link)
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
