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
                Text(text)
                    .font(.system(size: fontSize, weight: .bold))
                    .foregroundStyle(style.swiftUIColor)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, style.box ? fontSize * 0.3 : 0)
                    .padding(.vertical, style.box ? fontSize * 0.12 : 0)
                    .background {
                        if style.box { RoundedRectangle(cornerRadius: fontSize * 0.12).fill(.black.opacity(0.68)) }
                    }
                    .shadow(color: style.box ? .clear : .black.opacity(0.8), radius: fontSize / 20, y: fontSize / 30)
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
