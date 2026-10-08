import SwiftUI

// Liquid Glass on macOS 26 and later; regular materials and bordered buttons on macOS 14–15.

extension View {
    @ViewBuilder
    func glassBackground<S: Shape>(in shape: S, interactive: Bool = false, tint: Color? = nil) -> some View {
        if #available(macOS 26, *) {
            let glass: Glass = interactive ? .regular.interactive() : .regular
            glassEffect(tint.map { glass.tint($0) } ?? glass, in: shape)
        } else {
            background {
                shape.fill(.regularMaterial)
                if let tint { shape.fill(tint) }
            }
            .overlay { shape.stroke(.separator, lineWidth: 0.5) }
        }
    }

    @ViewBuilder
    func glassButtonStyle() -> some View {
        if #available(macOS 26, *) {
            buttonStyle(.glass)
        } else {
            buttonStyle(.bordered)
        }
    }

    @ViewBuilder
    func glassProminentButtonStyle() -> some View {
        if #available(macOS 26, *) {
            buttonStyle(.glassProminent)
        } else {
            buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder
    func softTopScrollEdge() -> some View {
        if #available(macOS 26, *) {
            scrollEdgeEffectStyle(.soft, for: .top)
        } else {
            self
        }
    }
}

/// Lets neighbouring glass shapes blend on macOS 26; a plain container elsewhere.
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat
    @ViewBuilder var content: Content

    var body: some View {
        if #available(macOS 26, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}
