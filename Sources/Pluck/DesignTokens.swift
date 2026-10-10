import SwiftUI

/// Pluck's design tokens: the sizes, spacing and shapes controls share, so a text field, a menu
/// and buttons that sit side by side line up exactly. Use these instead of numbers in views.
enum Design {
    enum Size {
        /// Every control in a bar: the link field, the format menu, the round buttons.
        static let control: CGFloat = 44
        /// Symbols inside bar controls.
        static let icon: CGFloat = 17
        /// The main action's symbol, a touch bolder.
        static let primaryIcon: CGFloat = 19
    }

    enum Spacing {
        /// Between controls in a bar.
        static let controls: CGFloat = 10
        /// Inside a capsule control, from its edge to its content.
        static let inset: CGFloat = 16
        /// Between a window's edge and its content.
        static let window: CGFloat = 20
        /// Around a sheet's or tool window's content.
        static let sheet: CGFloat = 24
        /// Between the parts of a sheet (header, form, notes, buttons).
        static let section: CGFloat = 16
        /// Between a header's symbol and its text.
        static let headerGap: CGFloat = 12
    }

    /// One scale of corner radii, from the smallest badge to the window-wide highlight.
    enum Radius {
        /// Duration badges on thumbnails.
        static let badge: CGFloat = 4
        /// Small thumbnails in lists, colour swatches.
        static let small: CGFloat = 6
        /// Small boxes and tiles.
        static let control: CGFloat = 8
        /// Thumbnails and previews.
        static let thumbnail: CGFloat = 10
        /// Grouped panels inside a window.
        static let box: CGFloat = 12
        /// Banners and cards on the main window.
        static let card: CGFloat = 16
        /// The drop highlight around the whole window.
        static let panel: CGFloat = 18
    }

    enum Typography {
        /// Text typed in, or chosen in, a bar control.
        static let control = Font.system(size: 15)
        /// Small counts and badges in a bar control.
        static let badge = Font.callout.weight(.medium)
        /// A sheet's title.
        static let sheetTitle = Font.title3.weight(.semibold)
        /// The big symbol next to a sheet's title.
        static let sheetSymbol = Font.largeTitle
        /// Notes under a form ("Runs on this Mac…").
        static let note = Font.callout
    }
}

/// The top of a sheet or tool window: its symbol, title and what it works on.
struct SheetHeader: View {
    let symbol: String
    let title: Text
    var subtitle: Text?
    /// An item's name: one line, shortened in the middle. Otherwise the subtitle wraps.
    var subtitleIsName = true

    var body: some View {
        HStack(spacing: Design.Spacing.headerGap) {
            Image(systemName: symbol)
                .font(Design.Typography.sheetSymbol)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                title.font(Design.Typography.sheetTitle)
                if let subtitle {
                    if subtitleIsName {
                        subtitle.foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    } else {
                        subtitle.foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

extension View {
    /// A note under a form, like "Runs on this Mac…": small, secondary, wrapping.
    func noteStyle() -> some View {
        font(Design.Typography.note)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// A capsule bar control: the shared height, inset and glass, for fields and menus.
    func barControl() -> some View {
        padding(.horizontal, Design.Spacing.inset)
            .frame(height: Design.Size.control)
            .glassBackground(in: .capsule, interactive: true)
    }
}

/// A round bar button with the shared size: plain glass, or filled with the accent colour for
/// the main action.
struct BarButtonStyle: ButtonStyle {
    var prominent = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: prominent ? Design.Size.primaryIcon : Design.Size.icon,
                          weight: prominent ? .semibold : .medium))
            .foregroundStyle(prominent ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .frame(width: Design.Size.control, height: Design.Size.control)
            .background {
                if prominent { Circle().fill(Color.accentColor) }
            }
            .glassBackground(in: .circle, interactive: true)
            .contentShape(.circle)
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.4)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }
}
