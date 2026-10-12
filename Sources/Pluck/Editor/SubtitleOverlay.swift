import SwiftUI

/// The subtitle on screen, drawn over the picture as it will be burned in: drag it to place it.
struct SubtitleOverlay: View {
    @Bindable var model: EditorModel
    @State private var dragStart: CGPoint?
    @State private var hovering = false

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let style = model.subtitleStyle
            // While placing it with nothing on screen, a sample shows where it goes.
            let text = model.subtitle(at: model.time)?.text ?? (dragStart != nil || hovering ? String(localized: "Subtitle") : nil)
            if let text {
                let fontSize = style.fontSize(height: size.height)
                // Outline and shadow are set for a 1080-line picture, like the export.
                let factor = size.height / 1080
                SubtitleText(text: style.shown(text), style: style, fontSize: fontSize, factor: factor)
                    .frame(maxWidth: size.width * 0.9)
                    .overlay {
                        if dragStart != nil || hovering {
                            RoundedRectangle(cornerRadius: 4).strokeBorder(Color.yellow, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                                .padding(-4)
                        }
                    }
                    .position(x: style.x * size.width, y: style.y * size.height)
                    .onHover { hovering = $0 }
                    .gesture(DragGesture()
                        .onChanged { value in
                            if dragStart == nil { dragStart = CGPoint(x: style.x, y: style.y) }
                            guard let start = dragStart else { return }
                            model.subtitleStyle.x = min(max(start.x + value.translation.width / size.width, 0.1), 0.9)
                            model.subtitleStyle.y = min(max(start.y + value.translation.height / size.height, 0.06), 0.96)
                        }
                        .onEnded { _ in
                            dragStart = nil
                            model.saveSubtitles()
                        })
                    .help("Drag to place the subtitles")
            }
        }
    }
}

/// One subtitle drawn as it's burned in: the font, weight and colour, with an outline (the text
/// drawn around itself in the outline's colour) or a box, and a shadow.
struct SubtitleText: View {
    let text: String
    let style: SubtitleStyle
    let fontSize: Double
    let factor: Double

    var body: some View {
        let outline = style.box ? 0 : style.outline * factor
        let shadow = style.shadow * factor
        label(style.swiftUIColor)
            .background {
                if outline > 0.2 {
                    ZStack {
                        ForEach(0..<12, id: \.self) { step in
                            let angle = Double(step) / 12 * 2 * .pi
                            label(style.swiftUIOutline).offset(x: cos(angle) * outline, y: sin(angle) * outline)
                        }
                    }
                }
            }
            .padding(.horizontal, style.box ? fontSize * 0.3 : 0)
            .padding(.vertical, style.box ? fontSize * 0.12 : 0)
            .background {
                if style.box { RoundedRectangle(cornerRadius: fontSize * 0.08).fill(style.swiftUIBox.opacity(style.boxOpacity)) }
            }
            .shadow(color: .black.opacity(shadow > 0 ? 0.55 : 0), radius: shadow * 0.6, x: shadow, y: shadow)
    }

    private func label(_ color: Color) -> some View {
        Text(text)
            .font(.custom(style.font, size: fontSize))
            .fontWeight(style.swiftUIWeight)
            .italic(style.italic)
            .foregroundStyle(color)
            .multilineTextAlignment(.center)
    }
}
