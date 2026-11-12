import SwiftUI

// Liquid Glass on macOS 26 and later; regular materials and bordered buttons on macOS 14–15.

enum Compat {
    /// Liquid Glass, unless the macOS 14–15 look is asked for (-PluckOldLook YES), to check
    /// that look on a newer Mac.
    static var glass: Bool {
        guard #available(macOS 26, *) else { return false }
        return !UserDefaults.standard.bool(forKey: "PluckOldLook")
    }
}

extension View {
    @ViewBuilder
    func glassBackground<S: Shape>(in shape: S, interactive: Bool = false, tint: Color? = nil) -> some View {
        if Edition.isStudio {
            // Pluck Studio has no glass: flat raised grey, as in its renders (owner, 2026-11-12).
            background {
                shape.fill(Design.Studio.raised)
                if let tint { shape.fill(tint) }
            }
        } else if #available(macOS 26, *), Compat.glass {
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
        if Edition.isStudio {
            buttonStyle(StudioFlatButtonStyle())
        } else if #available(macOS 26, *), Compat.glass {
            buttonStyle(.glass)
        } else {
            buttonStyle(.bordered)
        }
    }

    @ViewBuilder
    func glassProminentButtonStyle() -> some View {
        if Edition.isStudio {
            buttonStyle(StudioFlatButtonStyle(prominent: true))
        } else if #available(macOS 26, *), Compat.glass {
            buttonStyle(.glassProminent)
        } else {
            buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder
    func softTopScrollEdge() -> some View {
        if #available(macOS 26, *), Compat.glass, !Edition.isStudio {
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
        if #available(macOS 26, *), Compat.glass, !Edition.isStudio {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

/// Pluck Studio's plain button: raised grey, or deep plum with white text for the main action.
struct StudioFlatButtonStyle: ButtonStyle {
    var prominent = false
    /// 28 in rows and headers; 32 for a tool's main action (layout boards 6a–6h).
    var height: CGFloat = 28
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Design.Studio.body)
            .foregroundStyle(prominent ? Color.white : Design.Studio.text)
            .padding(.horizontal, 12)
            .frame(minHeight: height)
            .background(prominent ? AnyShapeStyle(Design.Brand.deep) : AnyShapeStyle(Design.Studio.raised),
                        in: .rect(cornerRadius: Design.Studio.controlRadius, style: .continuous))
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.4)
    }
}

extension ToolbarContent {
    /// Pluck Studio: no glass capsule behind a toolbar item, just the icon (as in its renders).
    @ToolbarContentBuilder
    func studioFlat() -> some ToolbarContent {
        if #available(macOS 26, *), Edition.isStudio {
            sharedBackgroundVisibility(.hidden)
        } else {
            self
        }
    }
}

extension View {
    /// A small action in a row ("Find", "Cut All"): Studio's flat grey button, a link in basic Pluck.
    @ViewBuilder
    func rowActionStyle() -> some View {
        if Edition.isStudio { buttonStyle(StudioFlatButtonStyle()) } else { buttonStyle(.link) }
    }
}
